#define MAX 4
#define NUM_SIMULATIONS 1
#define NUM_CAPABILITIES 2
#define CONCURRENT 0
#define SEQUENTIAL 1
#define ACCEPT 0
#define REJECT 1
#define CONTINUE 0
#define CANCEL 1

// =================================================================
// Model Event Flags
// =================================================================
bool e_TASK_READY_SENT = false
bool e_HELLO_TASK_SENT = false
bool e_CAP_COMPLETE[NUM_CAPABILITIES]
int e_CAP_OUTPUT[NUM_CAPABILITIES]
bool e_TASK_CANCEL = false
int e_CAP_CANCEL_COUNT = 0

// =================================================================
// Message Definitions
// =================================================================
mtype { LOAD_TASK, TASK_READY, REJECT_TASK, HELLO_CLIENT, START_CAPABILITY, CAPABILITY_INPUT, CAPABILITY_OUTPUT, CAPABILITY_COMPLETE, CANCEL_TASK, TASK_COMPLETE }
typedef Message {
	mtype topic
	int requestId
	int taskId
	int numCapabilities
	byte runMode
	int capabilityId
}

// initialize a channel which receiving task ready notifications
chan readyChannel = [0] of { Message }
// initialize a channel for each task where task manager can receive complete notification
chan completeChannel[NUM_SIMULATIONS] = [0] of { Message }
// initialize a channel for each task where capabilities can receive cancel command
chan cancelChannel[NUM_SIMULATIONS] = [MAX] of { Message }

// =================================================================
// Message Bus
// =================================================================
chan busInput = [MAX] of { Message }
chan busOutputs[MAX] = [MAX] of {Message}
bool activeBusOutputs[MAX]
int subscriberIndex = 0

proctype messageBus() {
	Message m
	do
	:: busInput ? m ->
		int i
		for (i : 0 .. MAX-1) {
			if
			:: (activeBusOutputs[i]) -> 
				busOutputs[i] ! m
			:: (!activeBusOutputs[i]) -> skip
			fi
		}
	:: timeout -> break
	od
}

// =================================================================
// Task Client
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
	Message m
	int i
	int requestId = 0
	for (i : 1 .. NUM_SIMULATIONS) {
		atomic {
			int concurrentOrSequential
			select(concurrentOrSequential : CONCURRENT .. SEQUENTIAL)
			m.topic = LOAD_TASK
			m.requestId = requestId
			m.runMode = concurrentOrSequential
			m.numCapabilities = NUM_CAPABILITIES
			requestId = requestId + 1
			busInput ! m
		}
	}

	// processing incoming messages
	do
	:: myBusOutput ? m -> 

		Message r
		if
		:: (TASK_READY == m.topic) ->
			printf("[Task client] TASK_READY received (requestId=%d, taskId=%d)\n", m.requestId, m.taskId)
		:: (REJECT_TASK == m.topic) ->
			printf("[Task client] REJECT_TASK received (requestId=%d)\n", m.requestId)
		:: (HELLO_CLIENT == m.topic) ->
			printf("[Task client] HELLO_CLIENT received (taskId=%d, capabilityId=%d)\n", m.taskId, m.capabilityId)
			atomic {
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
			atomic {
				m.topic = START_CAPABILITY
				busInput ! m	
			}
			atomic {
				m.topic = CAPABILITY_INPUT
				busInput ! m
			}
		:: (CAPABILITY_OUTPUT == m.topic) ->
			printf("[Task client] CAPABILITY_OUTPUT received (taskId=%d, capabilityId=%d)\n", m.taskId, m.capabilityId)
		:: (TASK_COMPLETE == m.topic) ->
			printf("[Task client TASK_COMPLETE received (taskId=%d)]\n", m.taskId)
			break
		:: else -> skip
		fi
	:: timeout -> break
	od

	atomic {
		activeBusOutputs[mySubscriberIndex] = false
	}
}

// =================================================================
// Task Manager
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
	
	// start a process to handle ready status
	// this simulates java observable
	run waitForReady()

	// process incoming messages
	Message m
	int taskId = 1;
	do
	:: myBusOutput ? m -> 
		if
		:: (LOAD_TASK == m.topic) -> 
			int acceptOrReject
			select(acceptOrReject : ACCEPT .. REJECT)
			if
			:: (REJECT == acceptOrReject) -> 
				atomic {
					printf("[Task manager] Task rejected, requestId = %d\n", m.requestId)
					m.topic = REJECT_TASK
					m.requestId = m.requestId
					busInput ! m
				}
			:: else -> 
				atomic {
					m.taskId = taskId
					taskId = taskId + 1
					printf("[Task manager] Task accepted, assigned id = %d\n", taskId)
					
					run waitForComplete(m.taskId, m.numCapabilities)
					run taskExecutor(m)
				}
			fi
		:: (CANCEL_TASK == m.topic) ->
			int i
			for (i : 1 .. m.numCapabilities) {
				atomic {
					cancelChannel[m.taskId-1] ! true
				}
			}
		:: else -> skip
		fi

	:: timeout -> break
	od

	atomic {
		activeBusOutputs[mySubscriberIndex] = false
	}	
}

proctype waitForReady() {
	Message ready
	do
	:: readyChannel ? ready ->
		atomic {
			printf("[Task manager] Task ready (id=%d)\n", ready.taskId)
			ready.topic = TASK_READY
			e_TASK_READY_SENT = true
			busInput ! ready
		}
	:: timeout -> break
	od
}

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
	:: timeout -> break
	od
}

// =================================================================
// Task Executor (and Task Strategy)
// =================================================================
proctype taskExecutor(Message m) {
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
		:: (CONCURRENT == m.runMode) -> run capability(m, capabilityCompletionCallback, false)
		:: (SEQUENTIAL == m.runMode) -> 
			run capability(m, capabilityCompletionCallback, true)
			capabilityCompletionCallback ? complete
		:: else -> skip
		fi
	}
}

// =================================================================
// Capability
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
	:: cancelChannel[m.taskId-1] ? cancel -> 
		printf("[Capability-%d-%d] Canceled\n", m.taskId, m.capabilityId)
		e_CAP_CANCEL_COUNT = e_CAP_CANCEL_COUNT + 1
		break
	:: myBusOutput ? m0 ->
		if
		:: (m.taskId == m0.taskId) ->
			if
			:: (m.capabilityId == m0.capabilityId) ->
				if
				:: (START_CAPABILITY == m0.topic) ->
					printf("[Capability-%d-%d] Start\n", m0.taskId, m0.capabilityId)
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
		:: (shouldCallback) -> callback ! true
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