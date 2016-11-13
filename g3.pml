// =================================================================
// Macros
//
// It defines global constants and some run time options
// =================================================================
#define MAX 4 				// The number of processes connecting to message bus simultaneously
#define NUM_SIMULATIONS 1	// Number of tasks to fire per simulation
#define NUM_CAPABILITIES 2	// Number of capabilities to create per task
#define CONCURRENT 0		// Execute capabilities concurrently
#define SEQUENTIAL 1		// Execute capabilities sequentially
#define ACCEPT 0			// Task manager will accept task request
#define REJECT 1			// Task manager will reject task request
#define CONTINUE 0			// Task client will let task complete
#define CANCEL 1			// Task client will cancel the task during processing

// =================================================================
// Model Event Flags
//
// Marked during execution and used in LTL for property assertion
// =================================================================
bool e_TASK_READY_SENT = false 			// task ready message is sent
bool e_HELLO_TASK_SENT = false 			// hello task message is sent
bool e_CAP_COMPLETE[NUM_CAPABILITIES] 	// capabilitiy component (for each capability)
int e_CAP_OUTPUT[NUM_CAPABILITIES] 		// capability output count (for each capability)
bool e_TASK_CANCEL = false 				// task cancel message is sent
int e_CAP_CANCEL_COUNT = 0 				// count that how many capabilities received cancel command

// =================================================================
// Message Definitions
//
// Defines the message types and message payload that is used throughout
// the model. Because Promela does not allow generic channel types, all
// possible parameters are put in Message type.
// =================================================================
mtype { LOAD_TASK, TASK_READY, REJECT_TASK, HELLO_CLIENT, START_CAPABILITY, CAPABILITY_INPUT, CAPABILITY_OUTPUT, CAPABILITY_COMPLETE, CANCEL_TASK, TASK_COMPLETE }
typedef Message {
	mtype topic 			// topic for this message
	int requestId			// request id, used by task client to identify message before taskId is assigned
	int taskId 				// task id assigned by task manager 
	int numCapabilities 	// (control info) number of capabilities to spawn, simulates task configuration
	byte runMode 			// (control info) run capabilities concurrently or sequentially, simulates task configuration
	int capabilityId 		// capability id assigned
}

// =================================================================
// Channels to simulate java Observable API
//
// Although we have a Message Bus, we choose to use separate channels
// to simulate the behaviour of Java Observable API, which is not
// expected to be synchronous when executed in different threads.
// =================================================================
// initialize a channel which receiving task ready "notifyObservers" calls
chan readyChannel = [0] of { Message }
// initialize a channel for each task where task manager can receive complete "notifyObservers" calls
chan completeChannel[NUM_SIMULATIONS] = [0] of { Message }
// initialize a channel for each task where capabilities can receive cancel command
chan cancelChannel[NUM_SIMULATIONS] = [MAX] of { Message }

// =================================================================
// Message Bus
//
// Simulates the GizmoMessageBus, uses broadcast based message delivery
// One main difference is that this bus also delivers to sender, we
// didn't change this behaviour since senders choose to react to messages
// based on topic and senders won't react to the message topic they send
// out anyways.
// =================================================================
chan busInput = [MAX] of { Message } 		// channel to send message (non-blocking)
chan busOutputs[MAX] = [MAX] of {Message} 	// channels to receive messages (non-blocking)
bool activeBusOutputs[MAX] 					// which receiving channels are active, inactive channels will be delivered
int subscriberIndex = 0 					// subscriber index for "activeBusOutputs" array and "busOutputs" array

// message bus main process
proctype messageBus() {
	Message m
	do
	:: busInput ? m ->
		int i
		for (i : 0 .. MAX-1) { 					// scan all receiving channels
			if
			:: (activeBusOutputs[i]) -> 
				busOutputs[i] ! m 				// deliver message if active
			:: (!activeBusOutputs[i]) -> skip
			fi
		}
	:: timeout -> break 						// avoid hard timeout
	od
}

// =================================================================
// Task Client
//
// Simulate the task client. A task client sends out LOAD_TASK message
// and await incoming messages to continue processing. It either actively
// CANCEL_TASK or TASK_COMPLETE eventually.
// =================================================================
proctype taskClient() {
	
	// connect to message bus and setup receiving channels
	int mySubscriberIndex
	atomic {
		mySubscriberIndex = subscriberIndex
		printf("[Task client] Acquired subscriber index: %d\n", mySubscriberIndex)
		subscriberIndex = subscriberIndex + 1
		activeBusOutputs[mySubscriberIndex] = true
	}
	chan myBusOutput = busOutputs[mySubscriberIndex]

	// generate LOAD_TASK messages
	// in this final version, we really only generate 1 LOAD_TASK message (NUM_SIMULATIONS=1)
	Message m
	int i
	int requestId = 0 	// create a local reference id so we know which TaskRSVP is rejected
	for (i : 1 .. NUM_SIMULATIONS) {
		atomic {
			// roll the dice on whether to concurrently or sequentially execute capabilities
			int concurrentOrSequential
			select(concurrentOrSequential : CONCURRENT .. SEQUENTIAL)
			// construct message
			m.topic = LOAD_TASK
			m.requestId = requestId
			m.runMode = concurrentOrSequential
			m.numCapabilities = NUM_CAPABILITIES
			requestId = requestId + 1
			// send LOAD_TASK message
			busInput ! m
		}
	}

	// processing incoming messages
	do
	:: myBusOutput ? m -> 
		Message r
		if
		// TASK_READY
		:: (TASK_READY == m.topic) ->
			printf("[Task client] TASK_READY received (requestId=%d, taskId=%d)\n", m.requestId, m.taskId)
		
		// REJECT_TASK
		:: (REJECT_TASK == m.topic) ->
			printf("[Task client] REJECT_TASK received (requestId=%d)\n", m.requestId)
		
		// HELLO_CLIENT
		:: (HELLO_CLIENT == m.topic) ->
			printf("[Task client] HELLO_CLIENT received (taskId=%d, capabilityId=%d)\n", m.taskId, m.capabilityId)
			// may or may not send out CANCEL_TASK message
			atomic {
				// roll the dice on whether to simulate CANCEL_TASK
				int cancelOrContinue
				select(cancelOrContinue : CONTINUE .. CANCEL)
				
				if
				:: (CANCEL == cancelOrContinue) ->
					atomic {
						m.topic = CANCEL_TASK
						printf("[Task client] Cancel Triggered (taskId=%d)\n", m.taskId)
						busInput ! m
						e_TASK_CANCEL = true
						skip
					}
				:: else -> skip
				fi
			}
			// send START_CAPABILITY message
			atomic {
				m.topic = START_CAPABILITY
				busInput ! m	
			}
			// send CAPABILITY_INPUT message
			atomic {
				m.topic = CAPABILITY_INPUT
				busInput ! m
			}
		
		// CAPABILITY_OUTPUT
		:: (CAPABILITY_OUTPUT == m.topic) ->
			printf("[Task client] CAPABILITY_OUTPUT received (taskId=%d, capabilityId=%d)\n", m.taskId, m.capabilityId)
		
		// TASK_COMPLETE
		:: (TASK_COMPLETE == m.topic) ->
			printf("[Task client TASK_COMPLETE received (taskId=%d)]\n", m.taskId)
			break
		:: else -> skip
		fi
	:: timeout -> break 	// avoid hard timeout
	od

	// de-register from message bus
	atomic {
		activeBusOutputs[mySubscriberIndex] = false
	}
}

// =================================================================
// Task Manager
//
// Task Manager handles incoming task request and facilitates task
// creation and destory
// =================================================================
proctype taskManager() {
	
	// connect to message bus and setup receiving channels
	int mySubscriberIndex
	atomic {
		mySubscriberIndex = subscriberIndex
		printf("[Task manager] Acquired subscriber index: %d\n", mySubscriberIndex)
		subscriberIndex = subscriberIndex + 1
		activeBusOutputs[mySubscriberIndex] = true
	}
	chan myBusOutput = busOutputs[mySubscriberIndex]
	
	// start a process to handle ready status, simulates Observable update API
	run waitForReady()

	// process incoming messages
	Message m
	int taskId = 1; 	// keep track of the task id assignment pool
	do
	:: myBusOutput ? m -> 
		if
		// LOAD_TASK message
		:: (LOAD_TASK == m.topic) -> 
			// roll the dice on whether to accept or reject this request, simulates preparing task that some preparation fails
			int acceptOrReject
			select(acceptOrReject : ACCEPT .. REJECT)
			
			if
			:: (REJECT == acceptOrReject) -> 
				// send REJECT_TASK message if decides to reject
				atomic {
					printf("[Task manager] Task rejected, requestId = %d\n", m.requestId)
					m.topic = REJECT_TASK
					m.requestId = m.requestId
					busInput ! m
				}
			:: else -> 
				// accepts the task
				atomic {
					m.taskId = taskId 		// obtain task id
					taskId = taskId + 1
					printf("[Task manager] Task accepted, assigned id = %d\n", taskId)
					// start process to simulate java Observable for completion
					run waitForComplete(m.taskId, m.numCapabilities)
					// start task executor to execute the task
					run taskExecutor(m)
				}
			fi

		// CANCEL_TASK message
		:: (CANCEL_TASK == m.topic) ->
			int i
			for (i : 1 .. m.numCapabilities) {
				atomic {
					// send out messages so that capabilities will know to self-destruct.
					// this simualtes TaskManager keeps track of all tasks and directly
					// call terminate() method on them.
					cancelChannel[m.taskId-1] ! true
				}
			}
		:: else -> skip
		fi

	:: timeout -> break 	// avoid hard timeout
	od

	// de-register from message bus
	atomic {
		activeBusOutputs[mySubscriberIndex] = false
	}	
}

// A process to handle TaskManager's task ready Java Observable call
proctype waitForReady() {
	Message ready
	do
	:: readyChannel ? ready ->
		// send TASK_READY message
		atomic {
			printf("[Task manager] Task ready (id=%d)\n", ready.taskId)
			ready.topic = TASK_READY
			e_TASK_READY_SENT = true
			busInput ! ready
		}
	:: timeout -> break 	// avoid hard timeout
	od
}

// A process to handle TaskManager's task complete Java Obseravable call
// taskId - the id of the task it is waiting for completion
// numCapabilities - the number of capabilities in that task, it needs to wait "numCapabilities" times before TASK_COMPLETE can be send out.
proctype waitForComplete(int taskId; int numCapabilities) {
	Message complete
	int i = 0
	do
	:: completeChannel[taskId-1] ? complete ->
		if
		:: (taskId == complete.taskId) ->
			atomic {
				i = i + 1
				if
				:: (i == numCapabilities) ->
					// all capabilities had completed, we are now sure of TASK_COMPLETE
					atomic {
						printf("[Task manager] Task complete (id=%d)\n", complete.taskId)
						complete.topic = TASK_COMPLETE
						busInput ! complete	
					}
				:: else -> skip
				fi
			}
		:: else -> skip
		fi
	:: timeout -> break 	// avoid hard timeout
	od
}

// =================================================================
// Task Executor (and Task Strategy)
//
// Simulates a task executor and the task strategy that it delegates
// its processing to. In the source code, TaskStrategy and TaskExecutor
// were executed in the same thread, hence we do not separate them in
// Promela.
// =================================================================
proctype taskExecutor(Message m) {
	// blocking channel used in sequential processing
	chan capabilityCompletionCallback = [0] of {bool}
	bool complete

	// abstract away the parsing process in strategy
	// notify that this task is ready
	m.topic = TASK_READY
	readyChannel ! m

	int i
	for (i : 1 .. m.numCapabilities) {
		m.capabilityId = i
		if
		// concurrently execute all capabilities
		:: (CONCURRENT == m.runMode) -> run capability(m, capabilityCompletionCallback, false)
		// sequentially execute all capabilities
		:: (SEQUENTIAL == m.runMode) -> 
			run capability(m, capabilityCompletionCallback, true)
			capabilityCompletionCallback ? complete 		// block until the last one notifies completion
		:: else -> skip
		fi
	}
}

// =================================================================
// Capability
//
// Simulates a capability that does the real work
// m - contains the detail of its execution
// callback - channel to notify completion during sequential execution
// shouldCallback - whether or not completion callback is necessary, indicates sequential processing if true
// =================================================================
proctype capability(Message m; chan callback; bool shouldCallback) {
	e_CAP_OUTPUT[m.capabilityId-1] = 0

	// connect to message bus and setup receiving channels
	int mySubscriberIndex
	atomic {
		mySubscriberIndex = subscriberIndex
		printf("[Capability-%d-%d] Acquired subscriber index: %d\n", m.taskId, m.capabilityId, mySubscriberIndex)
		subscriberIndex = subscriberIndex + 1
		activeBusOutputs[mySubscriberIndex] = true
	}
	chan myBusOutput = busOutputs[mySubscriberIndex]

	// send hello client
	atomic {
		m.topic = HELLO_CLIENT
		e_HELLO_TASK_SENT = true
		busInput ! m
	}

	// process messages
	Message m0
	bool cancel
	do
	// received cancel command, quit immediately
	:: cancelChannel[m.taskId-1] ? cancel -> 
		printf("[Capability-%d-%d] Canceled\n", m.taskId, m.capabilityId)
		e_CAP_CANCEL_COUNT = e_CAP_CANCEL_COUNT + 1
		break
	// received a message broadcast
	:: myBusOutput ? m0 ->
		if
		:: (m.taskId == m0.taskId) ->
			if
			:: (m.capabilityId == m0.capabilityId) ->
				if
				// START_CAPABILITY message
				:: (START_CAPABILITY == m0.topic) ->
					printf("[Capability-%d-%d] Start\n", m0.taskId, m0.capabilityId)
				
				// CAPABILITY_INPUT message
				:: (CAPABILITY_INPUT == m0.topic) ->
					printf("[Capability-%d-%d] Received input\n", m0.taskId, m0.capabilityId)
					
					atomic {
						// send output
						m0.topic = CAPABILITY_OUTPUT
						busInput ! m0
						printf("[Capability-%d-%d] Produced output\n", m0.taskId, m0.capabilityId)
						e_CAP_OUTPUT[m.capabilityId-1] = e_CAP_OUTPUT[m.capabilityId-1] + 1

						// send capability complete
						m0.topic = CAPABILITY_COMPLETE
						busInput ! m0
						printf("[Capability-%d-%d] Complete\n", m0.taskId, m0.capabilityId)
						e_CAP_COMPLETE[m.capabilityId-1] = true
						e_CAP_OUTPUT[m.capabilityId-1] = -1
					}
					// notify task manager I am complete
					atomic {
						completeChannel[m0.taskId-1] ! m0
						break
					}
				:: else -> skip
				fi
			:: else -> skip
			fi
		:: else -> skip
		fi
	:: timeout -> break
	od

	atomic {
		activeBusOutputs[mySubscriberIndex] = false
		printf("[Capability-%d-%d] Exits\n", m.taskId, m.capabilityId)
		if
		:: (shouldCallback) -> callback ! true	// about to exit process, send callback if in sequential mode
		:: else -> skip
		fi
	}
}

// =================================================================
// LTL
// =================================================================
ltl READY_BEFORE_HELLO { e_HELLO_TASK_SENT -> [](!e_TASK_READY_SENT U e_HELLO_TASK_SENT) }
ltl NO_OUTPUT_AFTER_COMPLETE { (e_CAP_COMPLETE[0] -> [](e_CAP_OUTPUT[0] == -1)) && (e_CAP_COMPLETE[1] -> [](e_CAP_OUTPUT[1] == -1)) }
ltl CANCEL_EVENTUAL_TERMINATE { e_TASK_CANCEL -> <>(e_CAP_CANCEL_COUNT == NUM_CAPABILITIES) }
ltl FIRST_CAP_ALWAYS_FINISH_BEFORE_SECOND { [](!e_CAP_COMPLETE[1] W !e_CAP_COMPLETE[0]) }

// =================================================================
// Init
// =================================================================
init {
	atomic {
		run messageBus()
		run taskManager()
		run taskClient()
	}
}