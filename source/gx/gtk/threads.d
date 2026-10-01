/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */
module gx.gtk.threads;

import core.memory;

import std.algorithm;
import std.experimental.logger;
import std.stdio;

import gdk.Threads;

/**
  * Simple structure that contains a pointer to a delegate. This is necessary because delegates are not directly
  * convertable to a simple pointer (which is needed to pass as data to a C callback).
  *
  * This code from grestful (https://github.com/Gert-dev/grestful)
  */
struct DelegatePointer(S, U...)
{
	S delegateInstance;

	U parameters;

	/**
      * Constructor.
      *
      * @param delegateInstance The delegate to invoke.
      * @param parameters       The parameters to pass to the delegate.
      */
	public this(S delegateInstance, U parameters)
	{
		this.delegateInstance = delegateInstance;
		this.parameters = parameters;
	}
}

/**
  * Callback that will invoke the passed DelegatePointer's delegate when it is called. This very useful method can be
  * used to pass delegates to gdk.Threads.threadsAddIdle instead of having to define a callback with C linkage and a
  * different method for every different action.
  *
  * The return type is the type that should be returned by this function. The invoked delegate should as a best practice
  * return the same value. If an exception happens and the value from the delegate can't be returned, the '.init' value
  * of the type will be used instead (or nothing in the case of void).
  *
  * Finally, if doRemoveRoot is set to true, this function will execute a removeRoot on the garbage collector for the
  * passed data (which is the delegate). This is useful in situations where you're passing a delegate to a C function
  * that will happen asynchronously, in which case you should be adding the newly allocated DelegatePointer using
  * addRoot to ensure the garbage collector doesn't attempt to collect the delegate while the callback hasn't been
  * invoked yet.
  *
  * @param data The data that is passed to the method.
  *
  * @return Whether or not the method should continue executing.
  *
  * This code from grestful (https://github.com/Gert-dev/grestful)
  */
extern(C) nothrow static ReturnType invokeDelegatePointerFunc(S, ReturnType, bool doRemoveRoot = false)(void* data)
{
	auto callbackPointer = cast(S*) data;

	try
	{
		static if (__traits(compiles, ReturnType.init))
		{
			auto returnValue = callbackPointer.delegateInstance(callbackPointer.parameters);
			return returnValue;
		}

		else
		{
			callbackPointer.delegateInstance(callbackPointer.parameters);
		}
	}

	catch (Exception e)
	{
		// Just catch it, can't throw D exceptions accross C boundaries.
		static if (__traits(compiles, ReturnType.init))
			return ReturnType.init;
	}

	// Should only end up here for types that don't have an initial value (such as void).
}

/**
 * Convenience method that allows scheduling a delegate to be executed with gdk.Threads.threadsAddIdle instead of a
 * traditional callback with C linkage.
 *
 * @param theDelegate The delegate to schedule.
 * @param parameters  A tuple of parameters to pass to the delegate when it is invoked.
 *
 * @example
 *     auto myMethod = delegate(string name, string value) { do_something_with_name_and_value(); }
 *     threadsAddIdleDelegate(myMethod, "thisIsAName", "thisIsAValue");
 *
 * This code from grestful (https://github.com/Gert-dev/grestful)
 */
void threadsAddIdleDelegate(T, parameterTuple...)(T theDelegate, parameterTuple parameters)
{
	void* delegatePointer = null;

	auto wrapperDelegate = (parameterTuple parameters) {
		bool callAgainNextIdleCycle = false;

		try
		{
			callAgainNextIdleCycle = theDelegate(parameters);
			//if (callAgainNextIdleCycle) trace("Callback again is true");
			//else trace("Callback again is false");
		}

		catch (Exception e)
		{
			warning("Unexpected exception occurred in wrapper");
			// Catch exceptions here as otherwise, memory may never be freed below.
		}

		if (!callAgainNextIdleCycle) {
			//trace("Removing delegate pointer");
			GC.removeRoot(delegatePointer);
			return false;
		} else return true;
	};

	delegatePointer = cast(void*) new DelegatePointer!(T, parameterTuple)(wrapperDelegate, parameters);

	// We're going into a separate thread and exiting here, make sure the garbage collector doesn't think the memory
	// isn't used anymore and collects it.
	GC.addRoot(delegatePointer);

	gdk.Threads.threadsAddIdle(
		cast(GSourceFunc) &invokeDelegatePointerFunc!(DelegatePointer!(T, parameterTuple), int),
		delegatePointer
		);
}

/**
 * Destroy notify that removes the garbage collector root added for a DelegatePointer
 * once GLib no longer references it.
 */
private extern(C) nothrow void removeDelegatePointerRoot(void* data)
{
	GC.removeRoot(data);
	version(unittest) delegateRootsReleased++;
}

// Lets the unit tests check that every root added is released
version(unittest) private __gshared int delegateRootsReleased;

/**
 * Convenience method that allows scheduling a delegate to be executed with gdk.Threads.threadsAddTimeout instead of a
 * traditional callback with C linkage.
 *
 * @param interval The interval to call the delegate in ms
 * @param theDelegate The delegate to schedule.
 * @param parameters  A tuple of parameters to pass to the delegate when it is invoked.
 *
 * @example
 *     auto myMethod = delegate(string name, string value) { do_something_with_name_and_value(); }
 *     threadsAddIdleDelegate(myMethod, "thisIsAName", "thisIsAValue");
 *
 * This code from grestful (https://github.com/Gert-dev/grestful)
 */
uint threadsAddTimeoutDelegate(T, parameterTuple...)(uint interval, T theDelegate, parameterTuple parameters)
{
	void* delegatePointer = null;

	auto wrapperDelegate = (parameterTuple parameters) {
		bool callAgainNextIdleCycle = false;

		try
		{
			callAgainNextIdleCycle = theDelegate(parameters);
			//if (callAgainNextIdleCycle) trace("Callback again is true");
			//else trace("Callback again is false");
		}

		catch (Exception e)
		{
			warning("Unexpected exception occurred in wrapper");
			// Catch exceptions here as otherwise, memory may never be freed below.
		}

		// The root is removed by removeDelegatePointerRoot when the source is destroyed
		return callAgainNextIdleCycle;
	};

	delegatePointer = cast(void*) new DelegatePointer!(T, parameterTuple)(wrapperDelegate, parameters);

	// We're going into a separate thread and exiting here, make sure the garbage collector doesn't think the memory
	// isn't used anymore and collects it.
	GC.addRoot(delegatePointer);

	// Use a destroy notify to remove the root rather than doing it when the delegate
	// returns false, otherwise the delegate leaks if the timeout is removed with
	// g_source_remove before it fires.
	enum G_PRIORITY_DEFAULT = 0;
	return gdk.Threads.threadsAddTimeoutFull(
		G_PRIORITY_DEFAULT,
		interval,
		cast(GSourceFunc) &invokeDelegatePointerFunc!(DelegatePointer!(T, parameterTuple), int),
		delegatePointer,
		cast(GDestroyNotify) &removeDelegatePointerRoot
		);
}

unittest {
	import core.thread : Thread;
	import core.time : Duration, msecs;
	import std.datetime.stopwatch : AutoStart, StopWatch;
	import glib.MainContext;
	import gtkc.glib;

	MainContext context = MainContext.default_();
	void iterateFor(Duration duration) {
		auto sw = StopWatch(AutoStart.yes);
		while (sw.peek() < duration) {
			while (context.iteration(false)) {}
			Thread.sleep(1.msecs);
		}
	}

	int released = delegateRootsReleased;

	// Fires once when the delegate returns false and releases its root
	int fired;
	bool delegate() once = () { fired++; return false; };
	uint id = threadsAddTimeoutDelegate(1, once);
	assert(id > 0);
	iterateFor(100.msecs);
	assert(fired == 1);
	assert(delegateRootsReleased == released + 1);

	// Repeats while the delegate returns true
	int repeats;
	bool delegate() repeat = () { return ++repeats < 3; };
	threadsAddTimeoutDelegate(1, repeat);
	iterateFor(200.msecs);
	assert(repeats == 3);
	assert(delegateRootsReleased == released + 2);

	// Removed before it fires, never runs and the root is still released,
	// previously this leaked the delegate and everything it referenced
	int removed;
	bool delegate() cancelled = () { removed++; return false; };
	id = threadsAddTimeoutDelegate(50, cancelled);
	g_source_remove(id);
	assert(delegateRootsReleased == released + 3);
	iterateFor(150.msecs);
	assert(removed == 0);
}
