#!/usr/bin/env ruby

require 'rubygems'
require 'yaml'
require 'tzinfo'
require File.dirname(__FILE__) + '/thartm_lib.rb'

class Rrtm 

	def initialize(key,secret,token)
		#@rtm = ThaRememberTheMilk.new(@@config['key'],@@config['secret'],@@config['token'])
		@rtm = ThaRememberTheMilk.new(key,secret,token)
		@rtm.use_user_tz = true
		@rtm.debug = true

		# id of the all tasks list
		@allTaskList = String.new 
		
		@lists = lists
		@timeline = @rtm.timelines.create
	end

	def allTaskList
		allTaskList = ''
		@lists.each do |k,v|
			if v[:name] == "All Tasks"
				allTaskList = v[:id]
			end
		end
		return allTaskList
	end

	def lists
		lists = @rtm.lists.getList
	end

	def tasks(args = {}) 
		tasks = @rtm.tasks.getList args 
		
	end

	def tasksAllTaskList
		t = tasks :list_id => allTaskList
	end

	
	def addTask(text, * args ) 
		if args.length == 1
			listname = args[0]
		end
	
		listid = 0
		if listname
		@lists.each do |k,v|
			if v[:name].match(listname)
				listid =  v[:id]
			end
		end
		end

		if listid != 0
			@rtm.tasks.add :timeline => @timeline, :name =>  text, :parse => '1', :list_id => listid
		else
			@rtm.tasks.add :timeline => @timeline, :name =>  text, :parse => '1'
		end
	end

	def findTask(id)
		tt = tasks
		tt.each do |key,val|
			val.each do |k,v|
				return  v if v[:id] == id
			end
		end
		return nil
	end

	def completeTask(id)
		v = findTask(id)
		@rtm.tasks.complete :timeline => @timeline,:list_id =>v.list_id , :taskseries_id => v.taskseries_id, :task_id => v.task_id
	end

	def postponeTask(id)
		v = findTask(id)
		@rtm.tasks.postpone :timeline => @timeline,:list_id =>v.list_id , :taskseries_id => v.taskseries_id, :task_id => v.task_id
	end

	def renameTask(id,newname)
		v = findTask(id)
		@rtm.tasks.setName :timeline => @timeline,:list_id =>v.list_id , :taskseries_id => v.taskseries_id, :task_id => v.task_id, :name => newname
	end

	def getTimezone
		sets = @rtm.settings.getList
		return sets[:timezone]
	end
end

class CommandLineInterface
	
	def initialize(key,secret,token)
		@rtm = Rrtm.new(key,secret,token)
	end

	def tasks
		t = Array.new
		tasks = @rtm.tasksAllTaskList	

		tasks.each do |key,val|
			val.each do |k,v|
				t.push(v) unless v.complete? # do not add c ompleted tasks
			end
		end

		# sorting by date (inverse order) and than by task name
		t.sort! do |a,b|
			if (a.has_due? and b.has_due?)
				a.due <=> b.due
			elsif a.has_due?
				-1
		    elsif b.has_due? 
				1
			else
			   a[:name] <=> b[:name] 
			end
		end

		# compose string result
		s = ''
		t.each do |tt|
			s += tt[:id] + ":  "  +   tt[:name].to_s + " -- " + tt.due.to_s + "\n"
		end
		puts s 
	end

	def add 
		@rtm.addTask(ARGV[1], ARGV[2] )
	end

	def lists
		l = @rtm.lists

		l.each do |k,v|
			puts v[:name]
		end
	end
	
	def complete
		@rtm.completeTask(ARGV[1])
	end

	def postpone
		@rtm.postpone(ARGV[1])
	end
	
	def tz
		return @rtm.getTimezone
	end
	def first
		t = Array.new
		tasks = @rtm.tasksAllTaskList	

		tasks.each do |key,val|
			val.each do |k,v|
				t.push(v) unless v.complete? # do not add c ompleted tasks
			end
		end

		# sorting by date (inverse order) and than by task name
		t.sort! do |a,b|
			if (a.has_due? and b.has_due?)
				a.due <=> b.due
			elsif a.has_due?
				-1
		    elsif b.has_due? 
				1
			else
			   a[:name] <=> b[:name] 
			end
		end

		# compose string result
		s = ''
		tt = t[0]
			s +=   tt[:name].to_s + " -- " + tt.due.to_s + "\n"
		puts s
	end

	def help
		s = ''
		s += 'Rrtm: Tha remember the milk Command Line Usage
usage rrtm <command> <params>

help: print this help and exits
lists: show available tasks lists
tasks: show not completed tasks
add name [lists name]: adds a task to the lists
complete id: mark task with id "id" as completed
postpone id: postpone task by one day
first: show first uncompleted task
'
	puts s
	end


end

#TODO gestione priorita' tasks
#TODO sort by priority? 

