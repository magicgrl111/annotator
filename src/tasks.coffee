
class _Task
  uniqueId: (length=8) ->
    id = ""
    id += Math.random().toString(36).substr(2) while id.length < length
    id.substr 0, length
        
  constructor: (info) ->
    unless info.manager?
      throw new Error "Trying to create task with no manager!"
    unless info.name?
      throw new Error "Trying to create task with no name!"
    unless info.code?
      throw new Error "Trying to define task with no code!"
    @manager = info.manager
    @log = @manager.log
    @taskID = this.uniqueId()
    @_name = info.name
    @_todo = info.code
    @_data = info.data
    info.deps ?= []
    this.setDeps info.deps
    @started = false
    @dfd = new jQuery.Deferred()

    @dfd._notify = @dfd.notify
    @dfd.notify = (data) => @dfd._notify $.extend data, task: this

    # Rename resolve to _resolve, so that nobody calls it by accident.
    @dfd._resolve = @dfd.resolve
    @dfd.resolve = -> throw new Error "Use ready() instead of resolve()!"

    @dfd._reject = @dfd.reject
    @dfd.reject = -> throw new Error "Use failed() instead of reject()!"

    @dfd.ready = (data) =>
      unless @dfd.state() is "pending"
        throw new Error "Called ready() on a task in state '" + @dfd.state() + "'!"
      endTime = new Date().getTime()
      elapsedTime = endTime - @dfd.startTime
      @dfd.notify
        progress: 1
        text: "Finished in " + elapsedTime + "ms."
      @dfd._resolve data

    @dfd.failed = (data) =>
      unless @dfd.state() is "pending"
        throw new Error "Called failed() on a task in state '" + @dfd.state() + "'!"
      endTime = new Date().getTime()
      elapsedTime = endTime - @dfd.startTime
      @dfd.notify
        progress: 1
        text: "Failed in " + elapsedTime + "ms."
      @dfd._reject data


    @dfd.promise this

  setDeps: (deps) ->
    @_deps = []
    this.addDeps deps

  addDeps: (toAdd) ->
    unless Array.isArray toAdd then toAdd = [toAdd]
    for dep in toAdd
      @_deps.push dep

  removeDeps: (toRemove) ->
    @log.debug "Should remove:", toRemove
    unless Array.isArray toRemove then toRemove = [toRemove]
    @_deps = @_deps.filter (dep) -> dep not in toRemove
    @log.debug "Deps now:",@_deps

  resolveDeps: ->
    @_depsResolved = ((if typeof dep is "string" then @manager.lookup dep else dep) for dep in @_deps)

  _start: =>
    if @started
      @log.debug "This task ('" + @_name + "') has already been started!"
      return
    unless @_depsResolved?
      throw Error "Dependencies are not resolved for task '"+ @_name +"'!"
    for dep in @_depsResolved
      unless dep.state() is "resolved"
        @log.debug "What am I doing here? Out of the " +
          @_depsResolved.length + " dependencies, '" + dep._name +
          "' for the current task '" + @_name +
          "' has not yet been resolved!"
        return

    @started = true
    setTimeout =>
      @dfd.notify
        progress: 0
        text: "Starting"
      @dfd.startTime = new Date().getTime()
      try
        @_todo @dfd, @_data
      catch exception
        @log.error "Error while executing task '" + @_name + "': " + exception
        @log.error exception
        @dfd.failed "Exception: " + exception.message

  _skip: =>
    if @started then return
    @started = true
    @dfd.notify
      progress: 1
      text: "Skipping, because some dependencies have failed."
    @dfd._reject()

class _TaskGen
  constructor: (info) ->
    @manager = info.manager
    @name = info.name
    @todo = info.code
    @count = 0

  create: (info, useDefaultProgress = true) ->
    @count += 1
    instanceInfo =
      name: @name + " #" + @count + ": " + info.instanceName
      code: @todo
      deps: info.deps
      data: info.data  
    @manager.create instanceInfo, useDefaultProgress

class _CompositeTask extends _Task
  constructor: (info) ->

    # Composite tasks are not supposed to have custom code.
    if info.code?
      throw new Error "You can not specify code for a CompositeTask!"

    # Instead, what they do is to resolve the "trigger" sub-task,
    # which is created automatically, and on which all other
    # sub-tasks depend on. So, in effect, running the task
    # allows to sub-tasks (that don't have other dependencies)
    # to execute.
    info.code = => @trigger.dfd._resolve()
 
    super info
    @subTasks = {}
    @pendingSubTasks = 0
    @failedSubTasks = 0
    @trigger = this.createSubTask
      weight: 0
      name: info.name + "__init"
      code: (task) ->
        # A trigget does not need to do anything.
        # Resolving the trigger task will trigger the rest of the tasks.

  _finished: ->
    if @failedSubTasks
      @dfd.failed()        
    else
      @dfd.ready()

  _deleteSubTask: (taskID) ->
    delete @subTasks[taskID]
    @pendingSubTasks -= 1

  addSubTask: (info) ->
    unless @dfd.state() is "pending"
      throw new Error "Can not add subTask to a finished task!"
    weight = info.weight
    unless weight?
      throw new Error "Trying to add subTask with no weight!"      
    task = info.task
    unless task?
      throw new Error "Trying to add subTask with no task!"
    if @trigger? then task.addDeps @trigger
    @subTasks[task.taskID] =
      name: task._name
      weight: weight
      progress: 0
      text: "no info about this subtask"
    @pendingSubTasks += 1

    task.done =>
      @pendingSubTasks -= 1
      this._finished() unless @pendingSubTasks

    task.fail =>
      @failedSubTasks += 1
      @pendingSubTasks -= 1
      this._finished() unless @pendingSubTasks
        
    task.progress (info) =>
      task = info.task

      # The trigger is a library internal thing.
      # We should not report anything about it.
      return if task is @trigger

      taskInfo = @subTasks[task.taskID]        
      for key, value of info
        unless key is "task"
          taskInfo[key] = value

      progress = 0
      totalWeight = 0
      for countId, countInfo of @subTasks
        progress += countInfo.progress * countInfo.weight
        totalWeight += countInfo.weight
      report =
        progress: progress / totalWeight

      if info.text?
        report.text = task._name + ": " + info.text

      @dfd.notify report

    task

  _getSubTaskIdByName: (name) ->
    ids = (id for id, info of @subTasks when info.name is name)
    if ids.length isnt 0 then ids[0] else null
        
  createSubTask: (info) ->
    w = info.weight
    delete info.weight

    oldSubTaskID = this._getSubTaskIdByName info.name
    if oldSubTaskID?
      @log.debug "When defining sub-task '" + info.name + "', overriding this existing sub-task: " + oldSubTaskID
      this._deleteSubTask oldSubTaskID

    this.addSubTask
      weight: w
      task: @manager.create(info, false)

  createDummySubTask: (info) ->
    this.addSubTask
      weight: 0
      task: @manager.createDummy(info, false)

class TaskManager
  constructor: (name) ->
    @name = name
    @log ?= getXLogger name + " TaskMan"
#    @log.setLevel XLOG_LEVEL.DEBUG
    @defaultProgressCallbacks = []

  addDefaultProgress: (callback) -> @defaultProgressCallbacks.push callback

  tasks: {}

  _checkName: (info) ->
    name = info?.name
    unless name?
      throw new Error "Trying to create a task without a name!"
    if @tasks[name]?
      @log.info "Overriding existing task '" + name +
        "' with new definition!"
    name

  create: (info, useDefaultProgress = true) ->
    name = this._checkName info
    info.manager = this
    task = new _Task info
    @tasks[task._name] = task
    if useDefaultProgress
      for cb in @defaultProgressCallbacks
        task.progress cb
    task

  createDummy: (info, useDefaultProgress = true) ->
    info.code = (task) -> task.ready()
    this.create info, useDefaultProgress  

  createGenerator: (info) ->
    info.manager = this
    new _TaskGen info

  createComposite: (info) ->
    name = this._checkName info
    info.manager = this
    task = new _CompositeTask info
    @tasks[name] = task
    for cb in @defaultProgressCallbacks
      task.progress cb
    task

  setDeps: (from, to) -> (@lookup from).setDeps to
  addDeps: (from, to) -> (@lookup from).addDeps to
  removeDeps: (from, to) -> (@lookup from).removeDeps to

  removeAllDepsTo: (to) ->
    throw new Error "Not yet implemented."

  lookup: (name) ->
    result = @tasks[name]
    unless result?
      @log.debug "Missing dependency: '" + name + "'."
      throw new Error "Looking up non-existant task '" + name + "'."
    result

  schedule: () ->
    for name, task of @tasks
      unless task.started
        try
          deps = task.resolveDeps()
          if deps.length is 0 and not task.started
            task._start()
          else if deps.length is 1
            deps[0].done task._start
            deps[0].fail task._skip
          else
            p = $.when.apply(null, deps)
            p.done task._start
            p.fail task._skip
          
        catch exception
          @log.debug "Could not resolve dependencies for task '" + name +
             "', so not scheduling it."

    null

  dumpPending: () ->
    failed = (name for name, task of @tasks when task.state() is "rejected")
    @log.info "Failed tasks:", failed

    resolved = (name for name, task of @tasks when task.state() is "resolved")
    @log.info "Finished tasks:", resolved

    running = (name for name, task of @tasks when task.state() is "pending" and task.started)
    @log.info "Currently running tasks:", running

    @log.info "Waiting tasks:"
    for name, task of @tasks when not task.started
      t = "Task '" + name + "'"
      @log.info "Analyzing waiting " + t
      try
        deps = task.resolveDeps()
        if deps.length is 0 and not task.started
          @log.info t + " has no dependencies; just nobody has started it. Schedule() ? "
        else
          pending = []
          for dep in deps
            if dep.state() is "pending"
              pending.push dep._name
          @log.info t + ": pending dependencies: ", pending    
        
      catch exception
        @log.info t + " has unresolved dependencies", exception
