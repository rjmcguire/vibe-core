/**
	Contains interfaces and enums for evented I/O drivers.

	Copyright: © 2012-2016 RejectedSoftware e.K.
	Authors: Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
*/
module vibe.core.task;

import vibe.core.log;
import vibe.core.sync;

import core.thread;
import std.exception;
import std.traits;
import std.typecons;
import std.variant;


/** Represents a single task as started using vibe.core.runTask.

	Note that the Task type is considered weakly isolated and thus can be
	passed between threads using vibe.core.concurrency.send or by passing
	it as a parameter to vibe.core.core.runWorkerTask.
*/
struct Task {
	private {
		shared(TaskFiber) m_fiber;
		size_t m_taskCounter;
		import std.concurrency : ThreadInfo, Tid;
		static ThreadInfo s_tidInfo;
	}

	private this(TaskFiber fiber, size_t task_counter)
	@safe nothrow {
		() @trusted { m_fiber = cast(shared)fiber; } ();
		m_taskCounter = task_counter;
	}

	this(in Task other) nothrow { m_fiber = cast(shared(TaskFiber))other.m_fiber; m_taskCounter = other.m_taskCounter; }

	/** Returns the Task instance belonging to the calling task.
	*/
	static Task getThis() nothrow @safe
	{
		// In 2067, synchronized statements where annotated nothrow.
		// DMD#4115, Druntime#1013, Druntime#1021, Phobos#2704
		// However, they were "logically" nothrow before.
		static if (__VERSION__ <= 2066)
			scope (failure) assert(0, "Internal error: function should be nothrow");

		auto fiber = () @trusted { return Fiber.getThis(); } ();
		if (!fiber) return Task.init;
		auto tfiber = cast(TaskFiber)fiber;
		assert(tfiber !is null, "Invalid or null fiber used to construct Task handle.");
		if (!tfiber.m_running) return Task.init;
		return () @trusted { return Task(tfiber, tfiber.m_taskCounter); } ();
	}

	nothrow {
		package @property inout(TaskFiber) taskFiber() inout @trusted { return cast(inout(TaskFiber))m_fiber; }
		@property inout(Fiber) fiber() inout @trusted { return this.taskFiber; }
		@property size_t taskCounter() const @safe { return m_taskCounter; }
		@property inout(Thread) thread() inout @safe { if (m_fiber) return this.taskFiber.thread; return null; }

		/** Determines if the task is still running.
		*/
		@property bool running()
		const @trusted {
			assert(m_fiber !is null, "Invalid task handle");
			try if (this.taskFiber.state == Fiber.State.TERM) return false; catch (Throwable) {}
			return this.taskFiber.m_running && this.taskFiber.m_taskCounter == m_taskCounter;
		}

		// FIXME: this is not thread safe!
		@property ref ThreadInfo tidInfo() { return m_fiber ? taskFiber.tidInfo : s_tidInfo; }
		@property Tid tid() { return tidInfo.ident; }
	}

	T opCast(T)() const nothrow if (is(T == bool)) { return m_fiber !is null; }

	void join() { if (running) taskFiber.join(m_taskCounter); }
	void interrupt() { if (running) taskFiber.interrupt(m_taskCounter); }

	string toString() const { import std.string; return format("%s:%s", cast(void*)m_fiber, m_taskCounter); }

	void getDebugID(R)(ref R dst)
	{
		import std.digest.md : MD5;
		import std.bitmanip : nativeToLittleEndian;
		import std.base64 : Base64;

		if (!m_fiber) {
			dst.put("----");
			return;
		}

		MD5 md;
		md.start();
		md.put(nativeToLittleEndian(cast(size_t)cast(void*)m_fiber));
		md.put(nativeToLittleEndian(cast(size_t)cast(void*)m_taskCounter));
		Base64.encode(md.finish()[0 .. 3], dst);
	}

	bool opEquals(in ref Task other) const nothrow @safe { return m_fiber is other.m_fiber && m_taskCounter == other.m_taskCounter; }
	bool opEquals(in Task other) const nothrow @safe { return m_fiber is other.m_fiber && m_taskCounter == other.m_taskCounter; }
}

/**
	Implements a task local storage variable.

	Task local variables, similar to thread local variables, exist separately
	in each task. Consequently, they do not need any form of synchronization
	when accessing them.

	Note, however, that each TaskLocal variable will increase the memory footprint
	of any task that uses task local storage. There is also an overhead to access
	TaskLocal variables, higher than for thread local variables, but generelly
	still O(1) (since actual storage acquisition is done lazily the first access
	can require a memory allocation with unknown computational costs).

	Notice:
		FiberLocal instances MUST be declared as static/global thread-local
		variables. Defining them as a temporary/stack variable will cause
		crashes or data corruption!

	Examples:
		---
		TaskLocal!string s_myString = "world";

		void taskFunc()
		{
			assert(s_myString == "world");
			s_myString = "hello";
			assert(s_myString == "hello");
		}

		shared static this()
		{
			// both tasks will get independent storage for s_myString
			runTask(&taskFunc);
			runTask(&taskFunc);
		}
		---
*/
struct TaskLocal(T)
{
	private {
		size_t m_offset = size_t.max;
		size_t m_id;
		T m_initValue;
		bool m_hasInitValue = false;
	}

	this(T init_val) { m_initValue = init_val; m_hasInitValue = true; }

	@disable this(this);

	void opAssign(T value) { this.storage = value; }

	@property ref T storage()
	{
		auto fiber = TaskFiber.getThis();

		// lazily register in FLS storage
		if (m_offset == size_t.max) {
			static assert(T.alignof <= 8, "Unsupported alignment for type "~T.stringof);
			assert(TaskFiber.ms_flsFill % 8 == 0, "Misaligned fiber local storage pool.");
			m_offset = TaskFiber.ms_flsFill;
			m_id = TaskFiber.ms_flsCounter++;


			TaskFiber.ms_flsFill += T.sizeof;
			while (TaskFiber.ms_flsFill % 8 != 0)
				TaskFiber.ms_flsFill++;
		}

		// make sure the current fiber has enough FLS storage
		if (fiber.m_fls.length < TaskFiber.ms_flsFill) {
			fiber.m_fls.length = TaskFiber.ms_flsFill + 128;
			fiber.m_flsInit.length = TaskFiber.ms_flsCounter + 64;
		}

		// return (possibly default initialized) value
		auto data = fiber.m_fls.ptr[m_offset .. m_offset+T.sizeof];
		if (!fiber.m_flsInit[m_id]) {
			fiber.m_flsInit[m_id] = true;
			import std.traits : hasElaborateDestructor, hasAliasing;
			static if (hasElaborateDestructor!T || hasAliasing!T) {
				void function(void[], size_t) destructor = (void[] fls, size_t offset){
					static if (hasElaborateDestructor!T) {
						auto obj = cast(T*)&fls[offset];
						// call the destructor on the object if a custom one is known declared
						obj.destroy();
					}
					else static if (hasAliasing!T) {
						// zero the memory to avoid false pointers
						foreach (size_t i; offset .. offset + T.sizeof) {
							ubyte* u = cast(ubyte*)&fls[i];
							*u = 0;
						}
					}
				};
				FLSInfo fls_info;
				fls_info.fct = destructor;
				fls_info.offset = m_offset;

				// make sure flsInfo has enough space
				if (ms_flsInfo.length <= m_id)
					ms_flsInfo.length = m_id + 64;

				ms_flsInfo[m_id] = fls_info;
			}

			if (m_hasInitValue) {
				static if (__traits(compiles, emplace!T(data, m_initValue)))
					emplace!T(data, m_initValue);
				else assert(false, "Cannot emplace initialization value for type "~T.stringof);
			} else emplace!T(data);
		}
		return (cast(T[])data)[0];
	}

	alias storage this;
}


/** Exception that is thrown by Task.interrupt.
*/
class InterruptException : Exception {
	this()
	@safe nothrow {
		super("Task interrupted.");
	}
}

/**
	High level state change events for a Task
*/
enum TaskEvent {
	preStart,  /// Just about to invoke the fiber which starts execution
	postStart, /// After the fiber has returned for the first time (by yield or exit)
	start,     /// Just about to start execution
	yield,     /// Temporarily paused
	resume,    /// Resumed from a prior yield
	end,       /// Ended normally
	fail       /// Ended with an exception
}

alias TaskEventCallback = void function(TaskEvent, Task) nothrow;

/**
	The maximum combined size of all parameters passed to a task delegate

	See_Also: runTask
*/
enum maxTaskParameterSize = 128;


/** The base class for a task aka Fiber.

	This class represents a single task that is executed concurrently
	with other tasks. Each task is owned by a single thread.
*/
final package class TaskFiber : Fiber {
	static if ((void*).sizeof >= 8) enum defaultTaskStackSize = 16*1024*1024;
	else enum defaultTaskStackSize = 512*1024;

	private {
		import std.concurrency : ThreadInfo;
		import std.bitmanip : BitArray;

		// task queue management (TaskScheduler.m_taskQueue)
		TaskFiber m_prev, m_next;
		TaskFiberQueue* m_queue;

		Thread m_thread;
		ThreadInfo m_tidInfo;
		shared size_t m_taskCounter;
		shared bool m_running;

		shared(ManualEvent) m_onExit;

		// task local storage
		BitArray m_flsInit;
		void[] m_fls;

		bool m_interrupt; // Task.interrupt() is progress

		static TaskFiber ms_globalDummyFiber;
		static FLSInfo[] ms_flsInfo;
		static size_t ms_flsFill = 0; // thread-local
		static size_t ms_flsCounter = 0;
	}


	package TaskFuncInfo m_taskFunc;
	package __gshared size_t ms_taskStackSize = defaultTaskStackSize;
	package __gshared debug TaskEventCallback ms_taskEventCallback;

	this()
	@trusted nothrow {
		super(&run, ms_taskStackSize);
		m_thread = Thread.getThis();
	}

	static TaskFiber getThis()
	@safe nothrow {
		auto f = () @trusted nothrow {
			return Fiber.getThis();
		} ();
		if (f) return cast(TaskFiber)f;
		if (!ms_globalDummyFiber) ms_globalDummyFiber = new TaskFiber;
		return ms_globalDummyFiber;
	}

	@property State state()
	@trusted const nothrow {
		return super.state;
	}


	private void run()
	{
		import std.encoding : sanitize;
		import std.concurrency : Tid;
		import vibe.core.core : isEventLoopRunning, recycleFiber, taskScheduler, yield;
		
		version (VibeDebugCatchAll) alias UncaughtException = Throwable;
		else alias UncaughtException = Exception;
		try {
			while (true) {
				while (!m_taskFunc.func) {
					try {
						Fiber.yield();
					} catch (Exception e) {
						logWarn("CoreTaskFiber was resumed with exception but without active task!");
						logDiagnostic("Full error: %s", e.toString().sanitize());
					}
				}

				auto task = m_taskFunc;
				m_taskFunc = TaskFuncInfo.init;
				Task handle = this.task;
				try {
					m_running = true;
					scope(exit) m_running = false;

					std.concurrency.thisTid; // force creation of a message box

					debug if (ms_taskEventCallback) ms_taskEventCallback(TaskEvent.start, handle);
					if (!isEventLoopRunning) {
						logTrace("Event loop not running at task start - yielding.");
						vibe.core.core.taskScheduler.yieldUninterruptible();
						logTrace("Initial resume of task.");
					}
					task.func(&task);
					debug if (ms_taskEventCallback) ms_taskEventCallback(TaskEvent.end, handle);
				} catch (Exception e) {
					debug if (ms_taskEventCallback) ms_taskEventCallback(TaskEvent.fail, handle);
					import std.encoding;
					logCritical("Task terminated with uncaught exception: %s", e.msg);
					logDebug("Full error: %s", e.toString().sanitize());
				}

				if (m_interrupt) {
					logDebug("Task exited while an interrupt was in flight.");
					m_interrupt = false;
				}

				this.tidInfo.ident = Tid.init; // clear message box

				logTrace("Notifying joining tasks.");
				m_onExit.emit();

				// make sure that the task does not get left behind in the yielder queue if terminated during yield()
				if (m_queue) m_queue.remove(this);

				// zero the fls initialization ByteArray for memory safety
				foreach (size_t i, ref bool b; m_flsInit) {
					if (b) {
						if (ms_flsInfo !is null && ms_flsInfo.length >= i && ms_flsInfo[i] != FLSInfo.init)
							ms_flsInfo[i].destroy(m_fls);
						b = false;
					}
				}

				// make the fiber available for the next task
				recycleFiber(this);
			}
		} catch(UncaughtException th) {
			logCritical("CoreTaskFiber was terminated unexpectedly: %s", th.msg);
			logDiagnostic("Full error: %s", th.toString().sanitize());
		}
	}


	/** Returns the thread that owns this task.
	*/
	@property inout(Thread) thread() inout @safe nothrow { return m_thread; }

	/** Returns the handle of the current Task running on this fiber.
	*/
	@property Task task() @safe nothrow { return Task(this, m_taskCounter); }

	@property ref inout(ThreadInfo) tidInfo() inout nothrow { return m_tidInfo; }

	@property size_t taskCounter() const { return m_taskCounter; }

	/** Blocks until the task has ended.
	*/
	void join(size_t task_counter)
	{
		while (m_running && m_taskCounter == task_counter)
			m_onExit.wait();
	}

	/** Throws an InterruptExeption within the task as soon as it calls an interruptible function.
	*/
	void interrupt(size_t task_counter)
	{
		import vibe.core.core : taskScheduler;

		if (m_taskCounter != task_counter)
			return;

		auto caller = Task.getThis();
		if (caller != Task.init) {
			assert(caller != this.task, "A task cannot interrupt itself.");
			assert(caller.thread is this.thread, "Interrupting tasks in different threads is not yet supported.");
		} else assert(Thread.getThis() is this.thread, "Interrupting tasks in different threads is not yet supported.");
		logTrace("Resuming task with interrupt flag.");
		m_interrupt = true;
		taskScheduler.switchTo(this.task);
	}

	void bumpTaskCounter()
	@safe nothrow {
		import core.atomic : atomicOp;
		() @trusted { atomicOp!"+="(this.m_taskCounter, 1); } ();
	}

	package void handleInterrupt(scope void delegate() @safe nothrow on_interrupt)
	@safe nothrow {
		assert(Task.getThis().fiber is this, "Handling interrupt outside of the corresponding fiber.");
		if (m_interrupt && on_interrupt) {
			logTrace("Handling interrupt flag.");
			m_interrupt = false;
			on_interrupt();
		}
	}

	package void handleInterrupt()
	@safe {
		if (m_interrupt)
			throw new InterruptException;
	}
}

package struct TaskFuncInfo {
	void function(TaskFuncInfo*) func;
	void[2*size_t.sizeof] callable = void;
	void[maxTaskParameterSize] args = void;

	@property ref C typedCallable(C)()
	{
		static assert(C.sizeof <= callable.sizeof);
		return *cast(C*)callable.ptr;
	}

	@property ref A typedArgs(A)()
	{
		static assert(A.sizeof <= args.sizeof);
		return *cast(A*)args.ptr;
	}

	void initCallable(C)()
	{
		C cinit;
		this.callable[0 .. C.sizeof] = cast(void[])(&cinit)[0 .. 1];
	}

	void initArgs(A)()
	{
		A ainit;
		this.args[0 .. A.sizeof] = cast(void[])(&ainit)[0 .. 1];
	}
}

package struct TaskScheduler {
	import eventcore.driver : ExitReason;
	import eventcore.core : eventDriver;

	private {
		TaskFiberQueue m_taskQueue;
		TaskFiber m_markerTask;
	}

	@safe:

	@disable this(this);

	@property size_t scheduledTaskCount() const nothrow { return m_taskQueue.length; }

	/** Lets other pending tasks execute before continuing execution.

		This will give other tasks or events a chance to be processed. If
		multiple tasks call this function, they will be processed in a
		fírst-in-first-out manner.
	*/
	void yield()
	{
		auto t = Task.getThis();
		if (t == Task.init) return; // not really a task -> no-op
		logTrace("Yielding (interrupt=%s)", t.taskFiber.m_interrupt);
		t.taskFiber.handleInterrupt();
		if (t.taskFiber.m_queue !is null) return; // already scheduled to be resumed
		m_taskQueue.insertBack(t.taskFiber);
		doYield(t);
		t.taskFiber.handleInterrupt();
	}

	nothrow:

	/** Performs a single round of scheduling without blocking.

		This will execute scheduled tasks and process events from the
		event queue, as long as possible without having to wait.

		Returns:
			A reason is returned:
			$(UL
				$(LI `ExitReason.exit`: The event loop was exited due to a manual request)
				$(LI `ExitReason.outOfWaiters`: There are no more scheduled
					tasks or events, so the application would do nothing from
					now on)
				$(LI `ExitReason.idle`: All scheduled tasks and pending events
					have been processed normally)
				$(LI `ExitReason.timeout`: Scheduled tasks have been processed,
					but there were no pending events present.)
			)
	*/
	ExitReason process()
	{
		bool any_events = false;
		while (true) {
			// process pending tasks
			schedule();

			logTrace("Processing pending events...");
			ExitReason er = eventDriver.processEvents(0.seconds);
			logTrace("Done.");

			final switch (er) {
				case ExitReason.exited: return ExitReason.exited;
				case ExitReason.outOfWaiters:
					if (!scheduledTaskCount)
						return ExitReason.outOfWaiters;
					break;
				case ExitReason.timeout:
					if (!scheduledTaskCount)
						return any_events ? ExitReason.idle : ExitReason.timeout;
					break;
				case ExitReason.idle:
					any_events = true;
					if (!scheduledTaskCount)
						return ExitReason.idle;
					break;
			}
		}
	}

	/** Performs a single round of scheduling, blocking if necessary.

		Returns:
			A reason is returned:
			$(UL
				$(LI `ExitReason.exit`: The event loop was exited due to a manual request)
				$(LI `ExitReason.outOfWaiters`: There are no more scheduled
					tasks or events, so the application would do nothing from
					now on)
				$(LI `ExitReason.idle`: All scheduled tasks and pending events
					have been processed normally)
			)
	*/
	ExitReason waitAndProcess()
	{
		// first, process tasks without blocking
		auto er = process();

		final switch (er) {
			case ExitReason.exited, ExitReason.outOfWaiters: return er;
			case ExitReason.idle: return ExitReason.idle;
			case ExitReason.timeout: break;
		}

		// if the first run didn't process any events, block and
		// process one chunk
		logTrace("Wait for new events to process...");
		er = eventDriver.processEvents();
		logTrace("Done.");
		final switch (er) {
			case ExitReason.exited: return ExitReason.exited;
			case ExitReason.outOfWaiters:
				if (!scheduledTaskCount)
					return ExitReason.outOfWaiters;
				break;
			case ExitReason.timeout: assert(false, "Unexpected return code");
			case ExitReason.idle: break;
		}

		// finally, make sure that all scheduled tasks are run
		er = process();
		if (er == ExitReason.timeout) return ExitReason.idle;
		else return er;
	}

	void yieldUninterruptible()
	{
		auto t = Task.getThis();
		if (t == Task.init) return; // not really a task -> no-op
		if (t.taskFiber.m_queue !is null) return; // already scheduled to be resumed
		m_taskQueue.insertBack(t.taskFiber);
		doYield(t);
	}

	/** Holds execution until the task gets explicitly resumed.

		
	*/
	void hibernate()
	{
		import vibe.core.core : isEventLoopRunning;
		auto thist = Task.getThis();
		if (thist == Task.init) {
			assert(!isEventLoopRunning, "Event processing outside of a fiber should only happen before the event loop is running!?");
			static import vibe.core.core;
			vibe.core.core.runEventLoopOnce();
		} else {
			doYield(thist);
		}
	}

	/** Immediately switches execution to the specified task without giving up execution privilege.

		This forces immediate execution of the specified task. After the tasks finishes or yields,
		the calling task will continue execution.
	*/
	void switchTo(Task t)
	{
		auto thist = Task.getThis();

		if (t == thist) return;

		auto thisthr = thist ? thist.taskFiber.thread : () @trusted { return Thread.getThis(); } ();
		assert(t.thread is thisthr, "Cannot switch to a task that lives in a different thread.");
		if (thist == Task.init) {
			resumeTask(t);
		} else {
			assert(!thist.taskFiber.m_queue, "Calling task is running, but scheduled to be resumed!?");
			if (t.taskFiber.m_queue) {
				logTrace("Task to switch to is already scheduled. Moving to front of queue.");
				assert(t.taskFiber.m_queue is &m_taskQueue, "Task is already enqueued, but not in the main task queue.");
				m_taskQueue.remove(t.taskFiber);
				assert(!t.taskFiber.m_queue, "Task removed from queue, but still has one set!?");
			}

			logTrace("Switching tasks");
			m_taskQueue.insertFront(thist.taskFiber);
			m_taskQueue.insertFront(t.taskFiber);
			doYield(thist);
		}
	}

	/** Runs any pending tasks.

		A pending tasks is a task that is scheduled to be resumed by either `yield` or
		`switchTo`.

		Returns:
			Returns `true` $(I iff) there are more tasks left to process.
	*/
	bool schedule()
	{
		if (!m_markerTask) m_markerTask = new TaskFiber; // TODO: avoid allocating an actual task here!

		assert(Task.getThis() == Task.init, "TaskScheduler.schedule() may not be called from a task!");
		assert(!m_markerTask.m_queue, "TaskScheduler.schedule() was called recursively!");

		// keep track of the end of the queue, so that we don't process tasks
		// infinitely
		m_taskQueue.insertBack(m_markerTask);

		while (m_taskQueue.front !is m_markerTask) {
			auto t = m_taskQueue.front;
			m_taskQueue.popFront();
			resumeTask(t.task);

			assert(!m_taskQueue.empty, "Marker task got removed from tasks queue!?");
			if (m_taskQueue.empty) return false; // handle gracefully in release mode
		}

		// remove marker task
		m_taskQueue.popFront();

		return !m_taskQueue.empty;
	}

	/// Resumes execution of a yielded task.
	private void resumeTask(Task t)
	{
		import std.encoding : sanitize;

		auto uncaught_exception = () @trusted nothrow { return t.fiber.call!(Fiber.Rethrow.no)(); } ();

		if (uncaught_exception) {
			auto th = cast(Throwable)uncaught_exception;
			assert(th, "Fiber returned exception object that is not a Throwable!?");

			assert(() @trusted nothrow { return t.fiber.state; } () == Fiber.State.TERM);
			logError("Task terminated with unhandled exception: %s", th.msg);
			logDebug("Full error: %s", () @trusted { return th.toString().sanitize; } ());

			// always pass Errors on
			if (auto err = cast(Error)th) throw err;
		}
	}

	private void doYield(Task task)
	{
		debug if (TaskFiber.ms_taskEventCallback) () @trusted { TaskFiber.ms_taskEventCallback(TaskEvent.yield, task); } ();
		() @trusted { Fiber.yield(); } ();
		debug if (TaskFiber.ms_taskEventCallback) () @trusted { TaskFiber.ms_taskEventCallback(TaskEvent.resume, task); } ();
	}
}

private struct TaskFiberQueue {
	@safe nothrow:

	TaskFiber first, last;
	size_t length;

	@disable this(this);

	@property bool empty() const { return first is null; }

	@property TaskFiber front() { return first; }

	void insertFront(TaskFiber task)
	{
		assert(task.m_queue is null, "Task is already scheduled to be resumed!");
		assert(task.m_prev is null, "Task has m_prev set without being in a queue!?");
		assert(task.m_next is null, "Task has m_next set without being in a queue!?");
		task.m_queue = &this;
		if (empty) {
			first = task;
			last = task;
		} else {
			first.m_prev = task;
			task.m_next = first;
			first = task;
		}
		length++;
	}

	void insertBack(TaskFiber task)
	{
		assert(task.m_queue is null, "Task is already scheduled to be resumed!");
		assert(task.m_prev is null, "Task has m_prev set without being in a queue!?");
		assert(task.m_next is null, "Task has m_next set without being in a queue!?");
		task.m_queue = &this;
		if (empty) {
			first = task;
			last = task;
		} else {
			last.m_next = task;
			task.m_prev = last;
			last = task;
		}
		length++;
	}

	void popFront()
	{
		if (first is last) last = null;
		assert(first && first.m_queue == &this, "Popping from empty or mismatching queue");
		auto next = first.m_next;
		if (next) next.m_prev = null;
		first.m_next = null;
		first.m_queue = null;
		first = next;
		length--;
	}

	void remove(TaskFiber task)
	{
		assert(task.m_queue is &this, "Task is not contained in task queue.");
		if (task.m_prev) task.m_prev.m_next = task.m_next;
		else first = task.m_next;
		if (task.m_next) task.m_next.m_prev = task.m_prev;
		else last = task.m_prev;
		task.m_queue = null;
		task.m_prev = null;
		task.m_next = null;
	}
}

private struct FLSInfo {
	void function(void[], size_t) fct;
	size_t offset;
	void destroy(void[] fls) {
		fct(fls, offset);
	}
}

