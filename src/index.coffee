# Spawn wrapper class
# =================================================
# This is an object oriented implementation arround the core `process.spawn`
# command.

# Node Modules
# -------------------------------------------------

# include base modules
debug = require('debug')('spawn')
debugCmd = require('debug')('spawn:cmd')
chalk = require 'chalk'
{spawn} = require 'child_process'
EventEmitter = require('events').EventEmitter
os = require 'os'
path = require 'path'
# include alinex modules
Config = require 'alinex-config'
# internal helpers
configcheck = require './configcheck'


# the expression to find detailed error messages in unknown processes
ERRORDETECT = /Error:\s((\w| )+)/i


# Class definition
# -------------------------------------------------
class Spawn extends EventEmitter

  @configcheck: configcheck

  @init: (@config = 'spawn', cb) ->
    # return if already initialized
    if @initDone
      cb() if cb
      return
    # start new initialization if not running
    unless @initStart
      @initStart = true
      debug "init or reinit spawn"
      # set config from different values
      if typeof @config is 'string'
        @config = Config.instance @config
        # add the module's directory as default
        @config.search.unshift path.resolve path.dirname(__dirname), 'var/local/config'
        @config.search.unshift path.resolve path.dirname(__dirname), 'var/src/config'
        # add the check methods
        @config.setCheck configcheck
      if @config instanceof Config
        @configClass = @config
        @config = @configClass.data
      @initDone = false # status set to true after initializing
    # set init status if configuration is loaded
    unless @configClass?
      cb() if cb?
      @initDone = true
    else
      # wait till configuration is loaded
      @configClass.load (err) =>
        console.error err if err
        cb err if cb?
        @initDone = true

  # overall runtime information
  @weight: 0
  @time: null
  @queue: 0

  # ### Get load limit
  # returns the load limit (between 0.8 and 4.0 with LOAD=1) the curve
  # is strong exponential, meaning higher priorities are higher load values allowed
  @load: (p) -> (3.2 * Math.pow((Math.exp(p)-1)/(Math.E-1),2) + 0.8) * @config.load.limit

  # ### Priority Up
  # This method calculates the new priority before a timeout.
  @priorityup: (p) -> 1 - Math.pow 1-p, 1.1

  # ### Priority Down
  # This method calculates the new priority before a retry.
  @prioritydown: (p) -> Math.pow p, 0.8

  # ### Timeout
  # This gives the number of milliseconds to wait
  @loadtimeout: (p, diff) ->
    q = switch
      when diff < 1.05 then 10
      when diff < 1.1 then 5
      when diff < 1.2 then 2
      else 1
    (59 * (1 - p) + 1) * @config.load.wait / q

  # ### Nice value
  # This brings the priorities to the operating system
  @nice: (p) ->
    v = if p > 1 then 0 else 1-p
    ~~(v*39 - 20)

  # ### General check method
  # This is used if no other check method given.
  @check = (proc) ->
    unless proc.code? and proc.code is 0
      msg = "Got exit code of #{proc.code}"
      # try to get detailed error message
      if proc.stderr.length
        match = proc.stderr.match ERRORDETECT
        msg += ' caused by ' + match[1] if match
      else
        match = proc.stdout.match ERRORDETECT
        msg += ' caused by ' + match[1] if match
      # create error message
      new Error "#{msg} in '#{proc.name}'."

  # Instance methods
  # -------------------------------------------------

  # ### Create instance
  constructor: (@config) ->
    @config.check = @constructor.check unless @config.check

  # ### Check if it can start
  loadcheck: (cb) =>
    return cb() if @priority > 1 # run immediately
    @constructor.queue--
    load = os.loadavg()[0] / os.cpus().length
    limit = @constructor.load @priority
    # load is ok, but check current added weight
    if load < limit
      # reset weight if new time (unit=10s)
      ntime = ~~(+new Date / @constructor.config.start.interval)
      if ntime isnt @constructor.time
        @constructor.time = ntime
        @constructor.weight = 0
      # calculate new weight
      name = path.basename(@config.cmd)
      nweight = if @constructor.config.weight[name]?
        @constructor.weight + @constructor.config.weight[name]
      else
        @constructor.weight + @constructor.config.weight.DEFAULT
      # check new weight > limit (timeout 1000)
      if @constructor.weight isnt 0 and nweight > @constructor.config.start.limit
        debug chalk.grey "current weight #{nweight} > #{@constructor.config.start.limit},
        waiting #{~~(@constructor.config.start.interval/1000)}s..."
        @constructor.queue++
        @emit 'wait', @constructor.config.start.interval
        return setTimeout (=> @loadcheck cb), @constructor.config.start.interval
      @constructor.weight = nweight
      return cb()
    # rerun check after timeout
    @priority = @constructor.priorityup @priority
    wait =  @constructor.loadtimeout @priority, load/limit
    wait += @constructor.queue*10 # add 10ms waiting time for each job in queue
    debug chalk.grey "load #{load.toFixed 2} > #{limit.toFixed 2} (p=#{@priority.toFixed 2}), waiting #{~~(wait/1000)}s"
    @constructor.queue++
    @emit 'wait', wait
    setTimeout (=> @loadcheck cb), wait

  # ### Start the process
  run: (cb) ->
    # start initializing, if not done
    unless Spawn.initDone?
      return Spawn.init null, => @run cb
    # wait till configuration is loaded
    if @constructor.configClass? and not @constructor.configClass.loaded
      return @constructor.configClass.load (err) =>
        return cb err if err
        @run cb
    # update config
    @config.priority ?= @constructor.config.defaults.priority
    @config.retry ?= @constructor.config.defaults.retry
    # init internal variables
    @retrycount = 0
    @priority = @config.priority
    @name = @config.name ? "#{path.basename @config.cmd} #{(@config.args ? []).join ' '}"
    # check system load
    debug "add job #{@name}"
    @_run cb

  _run: (cb) ->
    # check configuration
    unless @config.cmd
      err = new Error "No command specified for spawn."
      @emit 'error', err
      cb err if cb
      return
    @constructor.queue++
    @loadcheck =>
      debug "start job #{@name}"
      # cleanup result
      @stdout = @stderr = ''
      @end = @code = @error = null
      @start = new Date
      # create new subprocess
      cmd = @config.cmd
      args = []
      args = @config.args.slice 0 if @config.args?
      if process.platform is 'linux'
        # add support for nice call
        nice = @constructor.nice @priority
        args.unshift @config.cmd # command
        args.unshift @constructor.nice @priority # nice setting
        args.unshift '-n'
        cmd = 'nice'
      @proc = spawn cmd, args,
        cwd: @config.cwd
        env: @config.env
        uid: @config.uid
        gif: @config.gid
      @pid = @proc.pid
      debugCmd "[#{@pid}] #{@config.cmd} #{(@config.args ? []).join ' '}"
      # collect output
      stdout = stderr = ''
      @proc.stdout.setEncoding "utf8"
      @proc.stdout.on 'data', (data) =>
        stdout += data.toString()
        pos = stdout.lastIndexOf '\n'
        if ~pos++
          # copy into general buffer after line completed
          text = stdout.substring 0, pos
          stdout = stdout.substring pos
          @stdout += text
          @emit 'stdout', text # send through
          for line in text.split /\n/
            debugCmd chalk.grey "[#{@pid}] out: #{line}"
      @proc.stderr.setEncoding "utf8"
      @proc.stderr.on 'data', (data) =>
        stderr += data.toString()
        pos = stderr.lastIndexOf '\n'
        if ~pos++
          # copy into general buffer after line completed
          text = stderr.substring 0, pos
          stderr = stderr.substring pos
          @stderr += text
          @emit 'stderr', text # send through
          for line in text.split /\n/
            debugCmd chalk.grey "[#{@pid}] err: #{line}"
      # cleanup buffers
      bufferClean = =>
        if stdout
          @stdout = stdout
          @emit 'stdout', stdout
          debugCmd chalk.grey "[#{@pid}] out: #{stdout}"
        if stderr
          @stderr = stderr
          @emit 'stderr', stderr
          debugCmd chalk.grey "[#{@pid}] out: #{stderr}"
      # error management
      @proc.on 'error', (@err) =>
        if err.message is 'spawn EMFILE'
          debug chalk.grey "too much processes are opened, waiting 1s..."
          @emit 'wait', 1000
          return setTimeout (=> @_run cb), 1000
        bufferClean()
        @error = err
        @retry cb
      # process finished
      @proc.on 'close', (@code) =>
        @end = new Date
        bufferClean()
        debugCmd "[#{@pid}] exit: #{@code} after #{@end-@start}ms"
        @emit 'done', @code
        @error = @config.check @
        return @retry cb if @error
        cb @error, @stdout, @stderr, @code if cb

  # ### Retry process call after error
  retry: (cb) ->
    @priority = @constructor.prioritydown @priority
    if  @retrycount < @config.retry
      wait = Math.pow(++@retrycount, 3) * 1000
      debug "retry #{@retrycount+1}/#{@config.retry} in #{~~wait}s caused by #{@error}"
      @emit 'retry', wait
      return setTimeout (=> @_run cb), wait
    # end of retries
    @emit 'error', @error
    debugCmd chalk.red "[#{@pid}] #{@error.toString()}"
    cb @error, @stdout, @stderr, @code if cb


module.exports = Spawn
