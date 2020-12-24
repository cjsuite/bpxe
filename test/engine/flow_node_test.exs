defmodule BPXETest.Engine.FlowNode do
  use ExUnit.Case, async: true
  alias BPXE.Engine.{Blueprint, Process, FlowNode, Task}
  alias Process.Log
  doctest BPXE.Engine.FlowNode

  @xsi "http://www.w3.org/2001/XMLSchema-instance"

  test "sequence flow with no condition proceeds" do
    {:ok, pid} = Blueprint.start_link()
    {:ok, proc1} = Blueprint.add_process(pid, "proc1", %{"id" => "proc1", "name" => "Proc 1"})

    {:ok, start} = Process.add_event(proc1, "start", :startEvent, %{"id" => "start"})
    {:ok, the_end} = Process.add_event(proc1, "end", :endEvent, %{"id" => "end"})

    {:ok, _} = Process.establish_sequence_flow(proc1, "s1", start, the_end)

    {:ok, proc1} = Blueprint.instantiate_process(pid, "proc1")

    :ok = Process.subscribe_log(proc1)

    assert [{"proc1", [{"start", :ok}]}] |> List.keysort(0) ==
             Blueprint.start(pid) |> List.keysort(0)

    assert_receive({Log, %Log.EventActivated{id: "start"}})
    assert_receive({Log, %Log.EventActivated{id: "end"}})
  end

  test "sequence flow with a truthful condition proceeds" do
    {:ok, pid} = Blueprint.start_link()
    {:ok, proc1} = Blueprint.add_process(pid, "proc1", %{"id" => "proc1", "name" => "Proc 1"})

    {:ok, start} = Process.add_event(proc1, "start", :startEvent, %{"id" => "start"})
    {:ok, the_end} = Process.add_event(proc1, "end", :endEvent, %{"id" => "end"})

    {:ok, sf} = Process.establish_sequence_flow(proc1, "s1", start, the_end)

    FlowNode.add_condition_expression(sf, %{{@xsi, "type"} => "tFormalExpression"}, "`true`")

    {:ok, proc1} = Blueprint.instantiate_process(pid, "proc1")
    :ok = Process.subscribe_log(proc1)

    assert [{"proc1", [{"start", :ok}]}] |> List.keysort(0) ==
             Blueprint.start(pid) |> List.keysort(0)

    assert_receive({Log, %Log.EventActivated{id: "start"}})
    assert_receive({Log, %Log.EventActivated{id: "end"}})
  end

  test "sequence flow with a falsy condition does not proceed" do
    {:ok, pid} = Blueprint.start_link()
    {:ok, proc1} = Blueprint.add_process(pid, "proc1", %{"id" => "proc1", "name" => "Proc 1"})

    {:ok, start} = Process.add_event(proc1, "start", :startEvent, %{"id" => "start"})
    {:ok, the_end} = Process.add_event(proc1, "end", :endEvent, %{"id" => "end"})

    {:ok, sf} = Process.establish_sequence_flow(proc1, "s1", start, the_end)

    FlowNode.add_condition_expression(
      sf,
      %{{@xsi, "type"} => "tFormalExpression"},
      "`false`"
    )

    {:ok, proc1} = Blueprint.instantiate_process(pid, "proc1")
    :ok = Process.subscribe_log(proc1)

    assert [{"proc1", [{"start", :ok}]}] |> List.keysort(0) ==
             Blueprint.start(pid) |> List.keysort(0)

    assert_receive({Log, %Log.EventActivated{id: "start"}})
    refute_receive({Log, %Log.EventActivated{id: "end"}})
  end

  test "sequence flow conditions have access to all necessary variables" do
    # Current list:
    # `process` -- unbounded dictionary for process state
    # `flow_node` -- current flow_node
    {:ok, pid} = Blueprint.start_link()
    {:ok, proc1} = Blueprint.add_process(pid, "proc1", %{"id" => "proc1", "name" => "Proc 1"})

    {:ok, start} = Process.add_event(proc1, "start", :startEvent, %{"id" => "start"})
    {:ok, task} = Process.add_task(proc1, "task", :scriptTask, %{"id" => "task"})
    {:ok, _} = Task.add_script(task, ~s|
      process.proceed = true 
      flow_node.test = flow_node.id
      |)
    {:ok, the_end} = Process.add_event(proc1, "end", :endEvent, %{"id" => "end"})

    {:ok, _} = Process.establish_sequence_flow(proc1, "s1", start, task)
    {:ok, sf} = Process.establish_sequence_flow(proc1, "s2", task, the_end)

    # Ensure we have access to `process`
    FlowNode.add_condition_expression(
      sf,
      %{{@xsi, "type"} => "tFormalExpression"},
      ~s|process.proceed && flow_node.test == `"task"`|
    )

    {:ok, proc1} = Blueprint.instantiate_process(pid, "proc1")
    :ok = Process.subscribe_log(proc1)

    assert [{"proc1", [{"start", :ok}]}] |> List.keysort(0) ==
             Blueprint.start(pid) |> List.keysort(0)

    assert_receive({Log, %Log.EventActivated{id: "start"}})
    assert_receive({Log, %Log.TaskActivated{id: "task"}})
    assert_receive({Log, %Log.EventActivated{id: "end"}})
  end

  test "sequence flow conditions error will result in a log entry" do
    {:ok, pid} = Blueprint.start_link()
    {:ok, proc1} = Blueprint.add_process(pid, "proc1", %{"id" => "proc1", "name" => "Proc 1"})

    {:ok, start} = Process.add_event(proc1, "start", :startEvent, %{"id" => "start"})
    {:ok, the_end} = Process.add_event(proc1, "end", :endEvent, %{"id" => "end"})

    {:ok, sf} = Process.establish_sequence_flow(proc1, "s1", start, the_end)

    FlowNode.add_condition_expression(
      sf,
      %{{@xsi, "type"} => "tFormalExpression"},
      ~s|this is an invalid expression|
    )

    {:ok, proc1} = Blueprint.instantiate_process(pid, "proc1")
    :ok = Process.subscribe_log(proc1)

    assert [{"proc1", [{"start", :ok}]}] |> List.keysort(0) ==
             Blueprint.start(pid) |> List.keysort(0)

    assert_receive {Log,
                    %Log.ExpressionErrorOccurred{
                      id: "s1",
                      expression: "this is an invalid expression"
                    }}

    refute_receive({Log, %Log.FlowNodeActivated{id: "end"}})
  end
end
