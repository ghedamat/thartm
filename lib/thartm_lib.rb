# This file is part of the RTM Ruby API Wrapper.
#  
# The RTM Ruby API Wrapper is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as
# published by the Free Software Foundation; either version 2 of the
# License, or (at your option) any later version.  
# 
# The RTM Ruby API Wrapper is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#                                  
# You should have received a copy of the GNU General Public License
# along with the RTM Ruby API Wrapper; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
#
# (c) 2006, QuantumFoam.org, Inc.


#Modified by thamayor, mail: thamayor at gmail dot com
#my private rtm key is inside this file..

#this file is intended to be used with my rtm command line interface

#TODO add yaml api check?

require 'uri'
if /^1\.9/ === RUBY_VERSION then
    require 'digest/md5'
else
    require 'md5'
    require 'parsedate'
end
require 'cgi'
require 'net/http'
require 'date'
require 'time'
require 'rubygems'
require 'xml/libxml'
require 'tzinfo'


#TODO:  allow specifying whether retval should be indexed by rtm_id or list name for lists

class ThaRememberTheMilk

  RUBY_API_VERSION = '0.6'
  # you can just put set these here so you don't have to pass them in with 
  # every constructor call
  API_KEY = ''
  API_SHARED_SECRET = ''
  AUTH_TOKEN= ''
  
  
  Element = 0
  CloseTag = 1
  Tag = 2
  Attributes = 3
  #SelfContainedElement = 4
  TextNode = 4

  TagName = 0
  TagHash = 1
  
  
  attr_accessor :debug, :auth_token, :return_raw_response, :api_key, :shared_secret, :max_connection_attempts, :use_user_tz

  def user
    @user_info_cache[auth_token] ||= auth.checkToken.user
  end
  
  def user_settings
    @user_settings_cache[auth_token]
  end
  
  def get_timeline
    user[:timeline] ||= timelines.create
  end
  
  def time_to_user_tz( time )
    return time unless(@use_user_tz && @auth_token && defined?(TZInfo::Timezone))
    begin
      unless defined?(@user_settings_cache[auth_token]) && defined?(@user_settings_cache[auth_token][:tz])
        @user_settings_cache[auth_token] = settings.getList
        @user_settings_cache[auth_token][:tz] = TZInfo::Timezone.get(@user_settings_cache[auth_token].timezone)
      end
      debug "returning time in local zone(%s/%s)", @user_settings_cache[auth_token].timezone, @user_settings_cache[auth_token][:tz]
      @user_settings_cache[auth_token][:tz].utc_to_local(time)
    rescue Exception => err
      debug "unable to read local timezone for auth_token<%s>, ignoring timezone.  err<%s>", auth_token, err
      time
    end
  end

  def logout_user(auth_token)
    @auth_token = nil if @auth_token == auth_token
    @user_settings_cache.delete(auth_token)
    @user_info_cache.delete(auth_token)
  end
  
  # TODO: test efficacy of using https://www.rememberthemilk.com/services/rest/
  def initialize( api_key = API_KEY, shared_secret = API_SHARED_SECRET,  auth_token = AUTH_TOKEN, endpoint = 'http://www.rememberthemilk.com/services/rest/')
    @max_connection_attempts = 3
    @debug = false
    @api_key = api_key
    @shared_secret = shared_secret
    @uri = URI.parse(endpoint)
    #@auth_token = nil
    @auth_token = auth_token  
    @return_raw_response = false
    @use_user_tz = true
    @user_settings_cache = {}
    @user_info_cache = {}
    #@xml_parser = XML::Parser.new
    @xml_parser = XML::Parser.new(XML::Parser::Context.new)
  end
  
  def version() RUBY_API_VERSION  end
  
  def debug(*args)
    return unless @debug
    if defined?(RAILS_DEFAULT_LOGGER)
      RAILS_DEFAULT_LOGGER.warn( sprintf(*args) )
    else
      $stderr.puts(sprintf(*args))
    end
  end

  def auth_url( perms = 'delete' )
    auth_url = 'http://www.rememberthemilk.com/services/auth/'
    args = { 'api_key' => @api_key, 'perms' => perms }
    args['api_sig'] = sign_request(args)
    return auth_url + '?' + args.keys.collect {|k| "#{k}=#{args[k]}"}.join('&')
  end
  
  # this is a little fragile.  it assumes we are being invoked with RTM api calls
  # (which are two levels deep)
  # e.g.,
  # rtm = RememberTheMilk.new
  # data = rtm.reflection.getMethodInfo('method_name' => 'rtm.test.login')
  #  the above line gets turned into two calls, the first to this, which returns
  #  an RememberTheMilkAPINamespace object, which then gets *its* method_missing
  #  invoked with 'getMethodInfo' and the above args 
  #  i.e.,
  #   rtm.foo.bar
  #   rtm.foo() => a
  #   a.bar

  def method_missing( symbol, *args )
    rtm_namespace = symbol.id2name
    debug("method_missing called with namespace <%s>", rtm_namespace)
    RememberTheMilkAPINamespace.new( rtm_namespace, self )
  end
  
   def xml_node_to_hash( node, recursion_level = 0 )
    result = xml_attributes_to_hash( node.attributes )
    if node.element? == false
      result[node.name.to_sym] = node.content
    else
      node.each do |child| 
        name = child.name.to_sym
        value = xml_node_to_hash( child, recursion_level+1 )

        # if we have the same node name appear multiple times, we need to build up an array
        # of the converted nodes
        if !result.has_key?(name)
          result[name] = value
        elsif result[name].class != Array
          result[name] = [result[name], value]
        else
          result[name] << value
        end
      end
    end
    
    # top level nodes should be a hash no matter what
    (recursion_level == 0 || result.values.size > 1) ? result : result.values[0]
  end

  def xml_attributes_to_hash( attributes, class_name = RememberTheMilkHash )
    hash = class_name.send(:new)
    attributes.each {|a| hash[a.name.to_sym] = a.value} if attributes.respond_to?(:each)
    return hash
  end

  def index_data_into_hash( data, key )
    new_hash = RememberTheMilkHash.new

    if data.class == Array
      data.each {|datum| new_hash[datum[key]] = datum }
    else
      new_hash[data[key]] = data
    end

    new_hash
  end
    
  def parse_response(response,method,args)
# groups -- an array of group obj
# group -- some attributes and a possible contacts array
# contacts -- an array of contact obj
#  contact -- just attributes
# lists -- array of list obj
# list -- attributes and possible filter obj, and a set of taskseries objs?
#  task sereies obj are always wrapped in a list.  why?
# taskseries -- set of attributes, array of tags, an rrule, participants array of contacts, notes, 
# and task.  created and modified are time obj,
#  task -- attributes, due/added are time obj
# note -- attributes and a body of text, with created and modified time obj
# time -- convert to a time obj
# timeline -- just has a body of text
    return true unless response.keys.size > 1 # empty response (stat only)

    rtm_transaction = nil
    if response.has_key?(:transaction)
#      debug("got back <%s> elements in my transaction", response[:transaction].keys.size)
      # we just did a write operation, got back a transaction AND some data.  
      # Now, we will do some fanciness.
      rtm_transaction = response[:transaction]
    end

    response_types = response.keys - [:stat, :transaction]

    if response.has_key?(:api_key) # echo call, we assume
      response_type = :echo
      data = response
    elsif response_types.size > 1 
      error = RememberTheMilkAPIError.new({:code => "666", :msg=>"found more than one response type[#{response_types.join(',')}]"},method,args)
      debug( "%s", error )
      raise error
    else
      response_type = response_types[0] || :transaction
	  
      data = response[response_type]
    end

    case response_type
    when :auth
    when :frob
    when :echo
    when :transaction
    when :timeline
    when :methods
    when :settings
    when :contact
    when :group
      # no op
      
    when :tasks
	data = data[:list]
      new_hash = RememberTheMilkHash.new
      if data.class == Array                    # a bunch of lists
        data.each do |list| 
          if list.class == String  # empty list, just an id, so we create a stub
            new_list = RememberTheMilkHash.new
            new_list[:id] = list
            list = new_list
          end
          new_hash[list[:id]] = process_task_list( list[:id], list.arrayify_value(:taskseries) )
        end
        data = new_hash
      elsif data.class == RememberTheMilkHash  # only one list
	  #puts data.inspect
	  #puts data[:list][3][:taskseries].inspect
        data = process_task_list( data[:id], data.arrayify_value(:taskseries) )
      elsif data.class == NilClass || (data.class == String && data == args['list_id']) # empty list
        data = new_hash
      else                                      # who knows...  
        debug( "got a class of (%s [%s]) when processing tasks.  passing it on through", data.class, data )
      end
    when :groups
      # contacts expected to be array, so look at each group and fix it's contact
      data = [data] unless data.class == Array  # won't be array if there's only one group.  normalize here
      data.each do |datum| 
        datum.arrayify_value( :contacts )
      end
      data = index_data_into_hash( data, :id )
    when :time
      data = time_to_user_tz( Time.parse(data[:text]) )
    when :timezones
      data = index_data_into_hash( data, :name )
    when :lists
      data = index_data_into_hash( data, :id )
    when :contacts
      data = [data].compact unless data.class == Array
    when :list
      # rtm.tasks.add returns one of these, which looks like this:
      # <rsp stat='ok'><transaction id='978920558' undoable='0'/><list id='761280'><taskseries name='Try out Remember The Milk' modified='2006-12-19T22:07:50Z' url='' id='1939553' created='2006-12-19T22:07:50Z' source='api'><tags/><participants/><notes/><task added='2006-12-19T22:07:50Z' completed='' postponed='0' priority='N' id='2688677' has_due_time='0' deleted='' estimate='' due=''/></taskseries></list></rsp>
      # rtm.lists.add also returns this, but it looks like this:
      # <rsp stat='ok'><transaction id='978727001' undoable='0'/><list name='PersonalClone2' smart='0' id='761266' archived='0' deleted='0' position='0' locked='0'/></rsp>
      # so we can look for a name attribute
      if !data.has_key?(:name)
        data = process_task_list( data[:id], data.arrayify_value(:taskseries) )
        data = data.values[0] if data.values.size == 1
      end
    else
      throw "Unsupported reply type<#{response_type}>#{response.inspect}"
    end

    if rtm_transaction
      if !data.respond_to?(:keys)
        new_hash = RememberTheMilkHash.new
        new_hash[response_type] = data
        data = new_hash
      end
      
      if data.keys.size == 0
        data = rtm_transaction
      else
        data[:rtm_transaction] = rtm_transaction if rtm_transaction
      end
    end
    return data
  end
  

  def process_task_list( list_id, list )
    return {} unless list
    tasks = RememberTheMilkHash.new
    list.each do |taskseries_as_hash|
      taskseries = RememberTheMilkTask.new(self).merge(taskseries_as_hash)

      taskseries[:parent_list] = list_id  # parent pointers are nice
      taskseries[:tasks] = taskseries.arrayify_value(:task)
      taskseries.arrayify_value(:tags)
      taskseries.arrayify_value(:participants)
    
      # TODO is there a ruby lib that speaks rrule? 
      taskseries[:recurrence] = nil
      if taskseries[:rrule]
        taskseries[:recurrence] = taskseries[:rrule]
        taskseries[:recurrence][:rule] = taskseries[:rrule][:text]
      end

      taskseries[:completed] = nil
      taskseries.tasks.each do |item|
        if item.has_key?(:due) && item.due != ''
          item.due = time_to_user_tz( Time.parse(item.due) )
        end
        
        if item.has_key?(:completed) && item.completed != '' && taskseries[:completed] == nil
          taskseries[:completed] = true
        else  # once we set it to false, it can't get set to true
          taskseries[:completed] = false
        end
      end

      # TODO: support past tasks?
      tasks[taskseries[:id]] = taskseries
    end

    return tasks
  end
 
  def call_api_method( method, args={} )
    
    args['method'] = "rtm.#{method}"
    args['api_key'] = @api_key
    args['auth_token'] ||= @auth_token if @auth_token

    # make sure everything in our arguments is a string
    args.each do |key,value|
      key_s = key.to_s
      args.delete(key) if key.class != String
      args[key_s] = value.to_s
    end

    args['api_sig'] = sign_request(args)

    debug( 'rtm.%s(%s)', method, args.inspect )

    attempts_left = @max_connection_attempts
    
    begin
    if args.has_key?('test_data')
      @xml_parser.string = args['test_data']
    else
      attempts_left -= 1
      response = Net::HTTP.get_response(@uri.host, "#{@uri.path}?#{args.keys.collect {|k| "#{CGI::escape(k).gsub(/ /,'+')}=#{CGI::escape(args[k]).gsub(/ /,'+')}"}.join('&')}")
      debug('RESPONSE code: %s\n%sEND RESPONSE\n', response.code, response.body)
	  #puts response.body
      #@xml_parser.string = response.body
      @xml_parser= XML::Parser.string(response.body)
    end

      raw_data = @xml_parser.parse
      data = xml_node_to_hash( raw_data.root )
	  #puts data.inspect
      debug( "processed into data<#{data.inspect}>")
      
      if data[:stat] != 'ok'
        error = RememberTheMilkAPIError.new(data[:err],method,args)
        debug( "%s", error )
        raise error
      end
      #return return_raw_response ? @xml_parser.string : parse_response(data,method,args)
      return  parse_response(data,method,args)
    #rescue XML::Parser::ParseError => err
    #  debug("Unable to parse document.\nGot response:%s\nGot Error:\n", response.body, err.to_s)
    #  raise err
    rescue Timeout::Error => timeout
      $stderr.puts "Timed out to<#{endpoint}>, trying #{attempts_left} more times"
      if attempts_left > 0
        retry
      else
        raise timeout
      end
    end
  end
  
  def sign_request( args )
    if /^1\.9/ === RUBY_VERSION then
        return (Digest::MD5.new << @shared_secret + args.sort.flatten.join).to_s
    else
        return MD5.md5(@shared_secret + args.sort.flatten.join).to_s
    end
  end
end


## a pretty crappy exception class, but it should be sufficient for bubbling
## up errors returned by the RTM API (website)
class RememberTheMilkAPIError < RuntimeError
  attr_reader :response, :error_code, :error_message
  
  def initialize(error, method, args_to_method)
    @method_name = method
    @args_to_method = args_to_method
    @error_code = error[:code].to_i
    @error_message = error[:msg]
  end
  
  def to_s
    "Calling rtm.#{@method_name}(#{@args_to_method.inspect}) produced => <#{@error_code}>: #{@error_message}"
  end
end


## this is just a helper class so that you can do things like
## rtm.test.echo.  the method_missing in RememberTheMilkAPI returns one of
## these.
## this class is the "test" portion of the programming.  its method_missing then
## get invoked with "echo" as the symbol.  it has stored a reference to the original
## rtm object, so it can then invoke call_api_method
class RememberTheMilkAPINamespace
  def initialize(namespace, rtm)
    @namespace = namespace
    @rtm = rtm
  end
  
  def method_missing( symbol, *args )
    method_name = symbol.id2name
    @rtm.call_api_method( "#{@namespace}.#{method_name}", *args)
  end
end

## a standard hash with some helper methods
class RememberTheMilkHash < Hash
  attr_accessor :rtm
  
  @@strict_keys = true
  def self.strict_keys=( value )
    @@strict_keys = value
  end

  def initialize(rtm_object = nil)
    super
    @rtm = rtm_object
  end
  
  def id
    rtm_id || object_id
  end
  
  def rtm_id
    self[:id]
  end
  
  # guarantees that a given key corresponds to an array, even if it's an empty array
  def arrayify_value( key )
    if !self.has_key?(key)
      self[key] = []
    elsif self[key].class != Array
      self[key] = [ self[key] ].compact
    else
      self[key]
    end
  end
  
  
  def method_missing( key, *args )
    name = key.to_s
    
    setter = false
    if name[-1,1] == '='
      name = name.chop
      setter = true
    end

    if name == ""
      name = "rtm_nil".to_sym
    else
      name = name.to_sym
    end
    
    
    # TODO: should we allow the blind setting of values? (i.e., only do this test
    #  if setter==false )
    raise "unknown hash key<#{name}> requested for #{self.inspect}" if @@strict_keys && !self.has_key?(name)
    
    if setter
      self[name] = *args
    else
      self[name]
    end
  end
end


## TODO -- better rrule support.  start here with this code, commented out for now
## DateSet is to manage rrules
## this comes from the iCal ruby module as mentioned here:
## http://www.macdevcenter.com/pub/a/mac/2003/09/03/rubycocoa.html

# The API is aware it's creating tasks.  You may want to add semantics to a "task"
# elsewhere in your program.  This gives you that flexibility
# plus, we've added some helper methods

class RememberTheMilkTask < RememberTheMilkHash
  attr_accessor :rtm
  
  def timeline
    @timeline ||= rtm.get_timeline  # this caches timelines per user
  end

  def initialize( rtm_api_handle=nil )
    super
    @rtm = rtm_api_handle   # keep track of this so we can do setters (see factory below)
  end
  
  def task() tasks[-1] end
  def taskseries_id() self.has_key?(:taskseries_id) ? self[:taskseries_id] : rtm_id end
  def task_id() self.has_key?(:task_id) ? self[:task_id] : task.rtm_id end
  def list_id() parent_list end
  def due() task.due  end

  def has_due?()      due.class == Time                end
  def has_due_time?() task.has_due_time == '1'         end
  def complete?()     task[:completed] != ''          end
  def to_s
    a_parent_list = self[:parent_list] || '<Parent Not Set>'
    a_taskseries_id = self[:taskseries_id] || self[:id] || '<No Taskseries Id>'
    a_task_id = self[:task_id] || (self[:task] && self[:task].rtm_td) || '<No Task Id>' 
    a_name = self[:name] || '<Name Not Set>'
    "#{a_parent_list}/#{a_taskseries_id}/#{a_task_id}: #{a_name}"
  end

  def due_display
    if has_due? 
      if has_due_time?
        due.strftime("%a %d %b %y at %I:%M%p")
      else
        due.strftime("%a %d %b %y")
      end
    else 
      '[no due date]'
    end
  end

  @@BeginningOfEpoch = Time.parse("Jan 1 1904") # kludgey.. sure.  life's a kludge. deal with it.
  include Comparable
  def <=>(other)
    due = (has_key?(:tasks) && tasks.class == Array) ? task[:due] : nil
    due = @@BeginningOfEpoch unless due.class == Time
    other_due = (other.has_key?(:tasks) && other.tasks.class == Array) ? other.task[:due] : nil
    other_due = @@BeginningOfEpoch unless other_due.class == Time

    # sort based on priority, then due date, then name
    # which is the rememberthemilk default
    # if 0 was false in ruby, we could have done
    # prio <=> other_due || due <=> other_due || self['name'].to_s <=> other['name'].to_s
    # but it's not, so oh well....
    prio = priority.to_i
    prio += 666 if prio == 0  # prio of 0 is no priority which means it should show up below 1-3
    other_prio = other.priority.to_i
    other_prio += 666 if other_prio == 0

    if prio != other_prio
      return prio <=> other_prio
    elsif due != other_due
      return due <=> other_due
    else 
      # TODO: should this be case insensitive?  
      return self[:name].to_s <=> other[:name].to_s
    end
  end
  
  # Factory Methods... 
  # these are for methods that take arguments and apply to the taskseries
  # if you have RememberTheMilkTask called task, you might do:
  #  task.addTags( 'tag1, tag2, tag3' )
  #  task.setRecurrence   # turns off all rrules
  #  task.complete  # marks last task as complete
  #  task.setDueDate # unsets due date for last task
  #  task.setDueDate( nil, :task_id => task.tasks[0].id )  # unsets due date for first task in task array
  #  task.setDueDate( "tomorrow at 1pm", :parse => 1 )  # sets due date for last task to tomorrow at 1pm
  [['addTags','tags'], ['setTags', 'tags'], ['removeTags', 'tags'], ['setName', 'name'],
   ['setRecurrence', 'repeat'], ['complete', ''], ['uncomplete', ''], ['setDueDate', 'due'], 
    ['setPriority', 'priority'], ['movePriority', 'direction'], ['setEstimate', 'estimate'],
    ['setURL', 'url'], ['postpone', ''], ['delete', ''] ].each do |method_name, arg|
      class_eval <<-RTM_METHOD
     def #{method_name} ( value=nil, args={} )
       if @rtm == nil
        raise RememberTheMilkAPIError.new( :code => '667', :msg => "#{method_name} called without a handle to an rtm object [#{self.to_s}]" )
       end
       method_args = {}
       method_args["#{arg}"] = value if "#{arg}" != '' && value
       method_args[:timeline] = timeline
       method_args[:list_id] = list_id
       method_args[:taskseries_id] = taskseries_id
       method_args[:task_id] = task_id
       method_args.merge!( args )
       @rtm.call_api_method( "tasks.#{method_name}", method_args )  # returns the modified task
     end
     RTM_METHOD
  end

  # We have to do this because moveTo takes a "from_list_id", not "list_id", so the above factory
  #  wouldn't work.  sigh.
  def moveTo( to_list_id, args = {} )
    if @rtm == nil
      raise RememberTheMilkAPIError.new( :code => '667', :msg => "moveTO called without a handle to an rtm object [#{self.to_s}]" )
    end
    method_args = {}
    method_args[:timeline] = timeline
    method_args[:from_list_id] = list_id
    method_args[:to_list_id] = to_list_id
    method_args[:taskseries_id] = taskseries_id
    method_args[:task_id] = task_id
    method_args.merge( args )
    @rtm.call_api_method( :moveTo, method_args )
  end

end


# 
# class DateSet
#     
#     def initialize(startDate, rule)
#         @startDate = startDate
#         @frequency = nil
#         @count = nil
#         @untilDate = nil
#         @byMonth = nil
#         @byDay = nil
#         @starts = nil
#         if not rule.nil? then
#           @starts = rule.every == 1 ? 'every' : 'after'
#           parseRecurrenceRule(rule.rule)
#         end
#     end
#     
#     def parseRecurrenceRule(rule)
#       
#         if rule =~ /FREQ=(.*?);/ then
#             @frequency = $1
#         end
#         
#         if rule =~ /COUNT=(\d*)/ then
#             @count = $1.to_i
#         end
#         
#         if rule =~ /UNTIL=(.*?)[;\r]/ then
#             @untilDate = DateParser.parse($1)
#         end
#         
#         if rule =~ /INTERVAL=(\d*)/ then
#             @interval = $1.to_i
#         end
# 
#         if rule =~ /BYMONTH=(.*?);/ then
#             @byMonth = $1
#         end
# 
#         if rule =~ /BYDAY=(.*?);/ then
#             @byDay = $1
#             #puts "byDay = #{@byDay}"
#         end
#     end
#     
#     def to_s
#       # after/every  FREQ
#          puts "UNIMPLETEMENT"
# #        puts "#<DateSet: starts: #{@startDate.strftime("%m/%d/%Y")}, occurs: #{@frequency}, count: #{@count}, until: #{@untilDate}, byMonth: #{@byMonth}, byDay: #{@byDay}>"
#     end
#     
#     def includes?(date)
#         return true if date == @startDate
#         return false if @untilDate and date > @untilDate
#         
#         case @frequency
#             when 'DAILY'
#                 #if @untilDate then
#                 #   return (@startDate..@untilDate).include?(date)
#                 #end
#                 increment = @interval ? @interval : 1
#                 d = @startDate
#                 counter = 0
#                 until d > date
#                     
#                     if @count then
#                         counter += 1
#                         if counter >= @count
#                             return false
#                         end
#                     end
# 
#                     d += (increment * SECONDS_PER_DAY)
#                     if  d.day == date.day and 
#                         d.year == date.year and 
#                         d.month == date.month then
#                         puts "true for start: #{@startDate}, until: #{@untilDate}"
#                         return true
#                     end
# 
#                 end
#                 
#             when 'WEEKLY'
#                 return true if @startDate.wday == date.wday
#                 
#             when 'MONTHLY'
#                 
#             when 'YEARLY'
# 
#         end
#         
#         false
#     end
#     
#     attr_reader :frequency  
#     attr_accessor :startDate
# end
# 
