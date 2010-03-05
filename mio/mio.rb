#!/usr/bin/env ruby
# mio -- a lil tiny subset of Io all in Ruby for your own careful 
#        and private delectation w/ friends of the the family, 
#        if you want to.
# usage:
#   mio # starts the REPL
#   mio mio_on_rails.mio
# (c) macournoyer
module Mio
  class Object
    attr_accessor :protos, :value
    
    def initialize(value=nil, proto=Lobby[self.class.name.split("::").last])
      @value, @slots, @protos = value, {}, [proto].compact
    end
    
    def [](name)
      message = nil
      return message if message = @slots[name]
      @protos.each { |proto| return message if message = proto[name] }
      raise "Missing slot: #{name}"
    end
    
    def []=(name, message)
      @slots[name] = message
    end
    
    def call(*a)
      self
    end
    
    def to_ruby
      @value || self
    end
    
    def clone
      val = @value && @value.dup rescue TypeError
      Object.new(val, self)
    end
    
    def with(value)
      @value = value
      self
    end
    
    def to_s
      @value.to_s
    end
    
    def inspect
      "#<Mio::Object #{to_s} @slots=#{@slots.keys.inspect}>"
    end
  end
  
  # Message is a chain of tokens produced when parsing.
  #   1 print.
  # is parsed to:
  #   Message.new("1",
  #               Message.new("print"))
  # You can then +call+ the top level Message to eval it.
  class Message < Object
    attr_accessor :next, :previous, :name, :args
    
    def initialize(name=nil, _next=nil)
      @name, @args, self.next = name, [], _next
      super()
    end
    
    def next=(_next)
      _next.previous = self if _next
      @next = _next
    end
    
    def replace(with)
      @name, @args, @next, @previous = with.name, with.args, with.next, with.previous
      self
    end
    
    # Remove the message from the chain
    def pop(until_term=true)
      tail = @next
      tail = tail.next while until_term && tail && tail.name != "."
      prev = tail.previous if tail
      @previous.next = tail
      @previous = nil
      prev.next = nil if tail
      self
    end
    
    # Reorder messages so that:
    #  x = 1 id becomes =(x, 1 id)
    #  x + 1 becomes x +(1)
    def shuffle
      case @name
      when "="
        var = @previous.dup
        var.next = nil
        @args = [var, @next.pop]
        @previous.replace(self)
      when "+", "-", "*", "/", "<", ">", "==", "!=", "and", "or"
        @args = [@next.pop(false)]
      end
      @args.each { |arg| arg.shuffle }
      @next.shuffle if @next
      self
    end
    
    # Call (eval) the message on the +receiver+.
    def call(receiver, lobby=receiver, *args)
      # Find the slot
      slot = case @name
      when /^\./
        receiver = lobby # reset receiver
        nil
      when NilClass
        nil # HACK Fix this in parser instead
      when /^\d+/
        Lobby["Number"].clone.with(@name.to_i)
      when /^"(.*)"$/
        Lobby["String"].clone.with($1)
      else
        raise "calling #{@name} on nil" unless receiver
        receiver[@name]
      end
      
      # activate the slot
      if slot
        value = slot.call(receiver, receiver, *@args)
      else
        value = receiver
      end
      
      # pass to next if some
      if @next
        @next.call(value, lobby)
      else
        value
      end
    end
    
    def inspect
      s = @name.inspect
      s << @args.inspect unless @args.empty?
      s << " " + @next.inspect.to_s if @next
      s
    end
    
    # The simplest parsing code I could come up with.
    # Has some repetition I should get rid of.
    def self.parse(code)
      code = code.strip
      i = 0
      messages = [Message.new]
      while i < code.size
        case code[i]
        when ?.
          if messages.last.name
            messages.last.next = parse(code[i+1..-1]).last
          end
          messages.last.next = Message.new(code[i,1], messages.last.next)
          break
        when ?\s
          if messages.last.name
            messages.last.next = parse(code[i+1..-1]).last
            break
          end
        when ?"
          s = i
          i += 1
          i += 1 while code[i] != ?" && i < code.size
          messages.last.name = code[s..i]
        when ?\(
          s = i+1
          p = 1
          while p > 0 && i < code.size
            i += 1
            p += 1 if code[i] == ?\(
            p -= 1 if code[i] == ?\)
          end
          messages.last.args = parse(code[s..i-1])
        when ?,
          messages.concat parse(code[i+1..-1])
          break
        else
          messages.last.name = code[0..i]
        end
        i += 1
      end
      messages
    end
  end
  
  class Method < Object
    def initialize(receiver, lobby, body, args)
      @receiver, @lobby, @message, @args = receiver, lobby, body, args.map { |arg| arg.name }
      super()
    end
    
    def call(receiver, lobby, *args)
      context = @lobby.clone
      context["self"] = @receiver
      context["message"] = @message
      context["args"] = Lobby["List"].clone.with(args)
      context["eval_arg"] = proc { |caller, context, at| args[at.call(receiver).to_ruby].call(receiver) }
      @args.zip(args).each do |name, value|
        context[name] = (value || Lobby["nil"]).call(lobby)
      end
      @message.call(context, context, *args)
    end
  end

  def self.eval(code)
    # Parse
    message = Message.parse(code).first.shuffle
    # puts message.inspect
    # Eval
    message.call(Lobby)
  end
  
  # Bootstrap
  base = Object.new(nil, nil)
  object = base.clone
  
  base["clone"]    = proc { |caller, context| caller.clone }
  base["="]        = proc { |caller, context, name, value| caller[name.name] = value.call(caller) }
  base["set_slot"] = proc { |caller, context, name, value| caller[name.call(caller).to_ruby] = value.call(caller) }
  base["inspect"]  = proc { |caller, context| Lobby["String"].clone.with(caller.inspect) }
  base["id"]       = proc { |caller, context| Lobby["Number"].clone.with(caller.object_id) }
  base["print"]    = proc { |caller, context| puts caller.call(caller).to_ruby }
  base["do"]       = proc { |caller, context, body| body.call(caller); caller }
  base["ruby"]     = proc { |caller, context, code| Kernel.eval(code.call(caller).to_ruby) }
  base["method"]   = proc { |caller, context, *args| Method.new(caller, context, args.pop, args) }
  
  Lobby = base.clone
  object.protos.unshift(Lobby)
  
  Lobby["Lobby"]   = Lobby
  Lobby["Object"]  = object
  Lobby["nil"]     = object.clone.with(nil)
  Lobby["true"]    = object.clone.with(true)
  Lobby["false"]   = object.clone.with(false)
  Lobby["Number"]  = object.clone.with(0)
  Lobby["String"]  = object.clone.with("")
  Lobby["List"]    = object.clone.with([])
  Lobby["Message"] = object.clone
  Lobby["Method"]  = object.clone
  
  Lobby["list"] = proc { |caller, context, *items| Lobby["List"].clone.with(items) }
  Lobby["List"]["at"] = proc { |caller, context, at| caller.call(caller).to_ruby[at.call(caller).to_ruby] || Lobby["nil"] }
  Lobby["List"]["size"] = proc { |caller, context| Lobby["Number"].clone.with(caller.call(caller).to_ruby.size) }
  
  # TODO so incomplete, your eyes sound be bleeding by now.
  eval(<<-EOS)
    Object do(
      set_slot("and", method(eval_arg(0))).
      set_slot("or", method(self)).
    ).
    true do(
      
    ).
    nil do(
      set_slot("and", nil).
      set_slot("or", method(eval_arg(0))).
    ).
    false do(
      set_slot("and", false).
      set_slot("or", method(eval_arg(0))).
    ).
  EOS
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.empty?
    require "readline"
    loop do
      line = Readline::readline('> ')
      Readline::HISTORY.push(line)
      puts Mio.eval(line) rescue puts $!
    end
  else
    Mio.eval(File.read(ARGV[0]))
  end
end
