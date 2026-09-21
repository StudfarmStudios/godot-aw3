extends Node

class ThreadTrace:
	extends RefCounted
	var mutex := Mutex.new()
	var current := [[], []]

	func reset() -> void:
		mutex.lock()
		current[0].clear()
		current[1].clear()
		mutex.unlock()

	func record(group_id: int, order_id: int) -> void:
		mutex.lock()
		current[group_id].push_back(order_id)
		mutex.unlock()

	func snapshot() -> Array:
		mutex.lock()
		var result := [current[0].duplicate(), current[1].duplicate()]
		mutex.unlock()
		return result


class ProcessOrderNode:
	extends Node
	enum Mutation {
		NONE,
		REPARENT_SELF,
		REPARENT_TARGET,
		ADD_TARGET,
	}
	var order_id := -1
	var physics := false
	var controller: Node
	var mutation := Mutation.NONE
	var mutation_target: Node
	var mutation_parent: Node
	var mutation_done := false
	var thread_group_id := -1
	var thread_trace: ThreadTrace

	func _process(_delta: float) -> void:
		if not physics:
			record_process_callback()

	func _physics_process(_delta: float) -> void:
		if physics:
			record_process_callback()

	func record_process_callback() -> void:
		if thread_trace:
			thread_trace.record(thread_group_id, order_id)
		else:
			controller.record_callback(self)


var physics := false
var own_process_group := true
var sub_thread_pair := false
var callback_order: Array[int] = []
var captured_frames := []


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument == "--physics":
			physics = true
		elif argument == "--default-group":
			own_process_group = false
		elif argument == "--sub-thread-pair":
			sub_thread_pair = true
	call_deferred("run_sub_thread_pair" if sub_thread_pair else "run_scenario")


func set_processing_enabled(node: ProcessOrderNode, enabled: bool) -> void:
	if physics:
		node.set_process(false)
		node.set_physics_process(enabled)
	else:
		node.set_physics_process(false)
		node.set_process(enabled)


func set_processing_priority(node: ProcessOrderNode, priority: int) -> void:
	if physics:
		node.process_physics_priority = priority
	else:
		node.process_priority = priority


func record_callback(node: ProcessOrderNode) -> void:
	callback_order.push_back(node.order_id)
	if node.mutation_done:
		return
	node.mutation_done = true
	match node.mutation:
		ProcessOrderNode.Mutation.REPARENT_SELF:
			node.mutation_parent.remove_child(node)
			node.mutation_parent.add_child(node)
		ProcessOrderNode.Mutation.REPARENT_TARGET:
			node.mutation_parent.remove_child(node.mutation_target)
			node.mutation_parent.add_child(node.mutation_target)
		ProcessOrderNode.Mutation.ADD_TARGET:
			node.mutation_parent.add_child(node.mutation_target)


func capture_frame() -> void:
	callback_order.clear()
	if physics:
		await get_tree().physics_frame
	else:
		await get_tree().process_frame
	captured_frames.push_back(callback_order.duplicate())


func await_process_boundary() -> void:
	if physics:
		await get_tree().physics_frame
	else:
		await get_tree().process_frame


func capture_sub_thread_frame(trace: ThreadTrace, group_frames: Array) -> void:
	trace.reset()
	await await_process_boundary()
	var snapshot := trace.snapshot()
	group_frames[0].push_back(snapshot[0])
	group_frames[1].push_back(snapshot[1])


func run_scenario() -> void:
	var container := Node.new()
	container.name = "ProcessGroupOwner"
	if own_process_group:
		container.process_thread_group = Node.PROCESS_THREAD_GROUP_MAIN_THREAD
	var holder := Node.new()
	holder.name = "ReparentHolder"
	container.add_child(holder)
	add_child(container)

	var nodes: Array[ProcessOrderNode] = []
	for id in range(6):
		var node := ProcessOrderNode.new()
		node.name = "ProcessNode%d" % id
		node.order_id = id
		node.physics = physics
		node.controller = self
		set_processing_enabled(node, true)
		nodes.push_back(node)
		if id < 5:
			container.add_child(node)

	# Align the coroutine with the signal emitted immediately before the chosen
	# process pass. Every capture below then spans exactly one callback pass.
	if physics:
		await get_tree().physics_frame
	else:
		await get_tree().process_frame

	await capture_frame()
	container.add_child(nodes[5])
	await capture_frame()
	set_processing_enabled(nodes[2], false)
	set_processing_enabled(nodes[2], true)
	await capture_frame()
	set_processing_priority(nodes[4], -10)
	await capture_frame()
	container.move_child(nodes[3], 0)
	await capture_frame()
	set_processing_enabled(nodes[1], false)
	set_processing_enabled(nodes[1], true)
	await capture_frame()
	nodes[2].reparent(holder)
	await capture_frame()

	nodes[4].mutation = ProcessOrderNode.Mutation.REPARENT_TARGET
	nodes[4].mutation_target = nodes[3]
	nodes[4].mutation_parent = container
	nodes[4].mutation_done = false
	await capture_frame()
	await capture_frame()

	nodes[4].mutation = ProcessOrderNode.Mutation.REPARENT_SELF
	nodes[4].mutation_parent = container
	nodes[4].mutation_done = false
	await capture_frame()
	await capture_frame()

	var added := ProcessOrderNode.new()
	added.name = "ProcessNode6"
	added.order_id = 6
	added.physics = physics
	added.controller = self
	set_processing_enabled(added, true)
	nodes[4].mutation = ProcessOrderNode.Mutation.ADD_TARGET
	nodes[4].mutation_target = added
	nodes[4].mutation_done = false
	await capture_frame()
	await capture_frame()

	var valid := captured_frames.size() == 13
	valid = valid and captured_frames[7].count(3) == 0
	valid = valid and captured_frames[9].count(4) == 1
	valid = valid and captured_frames[11].count(6) == 0
	valid = valid and captured_frames[12].count(6) == 1
	var mode := "physics" if physics else "idle"
	var group := "dedicated" if own_process_group else "default"
	print("PROCESS_ORDER_ORACLE mode=%s group=%s valid=%s trace=%s" % [mode, group, valid, JSON.stringify(captured_frames)])
	get_tree().quit(0 if valid else 1)


func run_sub_thread_pair() -> void:
	var trace := ThreadTrace.new()
	var group_frames := [[], []]
	var containers := []
	var holders := []
	var nodes := [[], []]

	for group_id in range(2):
		var container := Node.new()
		container.name = "SubThreadGroup%d" % group_id
		container.process_thread_group = Node.PROCESS_THREAD_GROUP_SUB_THREAD
		var holder := Node.new()
		holder.name = "ReparentHolder"
		container.add_child(holder)
		add_child(container)
		containers.push_back(container)
		holders.push_back(holder)

		for id in range(6):
			var node := ProcessOrderNode.new()
			node.name = "ProcessNode%d" % id
			node.order_id = id
			node.physics = physics
			node.thread_group_id = group_id
			node.thread_trace = trace
			set_processing_enabled(node, true)
			nodes[group_id].push_back(node)
			if id < 5:
				container.add_child(node)

	# The signal is emitted on the main thread before process groups run. Waiting
	# once aligns all later mutations with a boundary after prior worker tasks have
	# joined and before the next pair is dispatched.
	await await_process_boundary()

	await capture_sub_thread_frame(trace, group_frames)
	for group_id in range(2):
		containers[group_id].add_child(nodes[group_id][5])
	await capture_sub_thread_frame(trace, group_frames)
	for group_id in range(2):
		set_processing_enabled(nodes[group_id][2], false)
		set_processing_enabled(nodes[group_id][2], true)
	await capture_sub_thread_frame(trace, group_frames)
	for group_id in range(2):
		set_processing_priority(nodes[group_id][4], -10)
	await capture_sub_thread_frame(trace, group_frames)
	for group_id in range(2):
		containers[group_id].move_child(nodes[group_id][3], 0)
	await capture_sub_thread_frame(trace, group_frames)
	for group_id in range(2):
		set_processing_enabled(nodes[group_id][1], false)
		set_processing_enabled(nodes[group_id][1], true)
	await capture_sub_thread_frame(trace, group_frames)
	for group_id in range(2):
		nodes[group_id][2].reparent(holders[group_id])
	await capture_sub_thread_frame(trace, group_frames)
	for group_id in range(2):
		containers[group_id].remove_child(nodes[group_id][3])
	await capture_sub_thread_frame(trace, group_frames)
	for group_id in range(2):
		containers[group_id].add_child(nodes[group_id][3])
	await capture_sub_thread_frame(trace, group_frames)

	var expected := [
		[0, 1, 2, 3, 4],
		[0, 1, 2, 3, 4, 5],
		[0, 1, 2, 3, 4, 5],
		[4, 0, 1, 2, 3, 5],
		[4, 0, 1, 2, 3, 5],
		[4, 3, 0, 1, 2, 5],
		[4, 3, 2, 0, 1, 5],
		[4, 2, 0, 1, 5],
		[4, 2, 0, 1, 5, 3],
	]
	var valid: bool = group_frames[0] == expected and group_frames[1] == expected
	var mode := "physics" if physics else "idle"
	print("PROCESS_ORDER_SUBTHREAD_ORACLE mode=%s valid=%s group0=%s group1=%s" % [mode, valid, JSON.stringify(group_frames[0]), JSON.stringify(group_frames[1])])
	get_tree().quit(0 if valid else 1)
