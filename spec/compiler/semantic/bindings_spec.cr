require "../../spec_helper"

private SLOTS = Crystal::ASTBase::LINK_SLOTS

private class UpdateCounter < Crystal::Nop
  getter updates = 0

  def update(from = nil)
    @updates += 1
    super
  end
end

# Runs a block the first time it is updated.
private class UpdateHook < Crystal::Nop
  getter updates = 0

  def initialize(&@hook : ->)
  end

  def update(from = nil)
    @updates += 1
    if hook = @hook
      @hook = nil
      hook.call
    end
  end
end

# Returns the link slots of a node.
private def link_slots(node : ASTBase) : Array(ASTBase | Array(ASTBase) | Nil)
  {% begin %}
    [{% for index in 0...Crystal::ASTBase::LINK_SLOTS %} node.@link{{index}}, {% end %}] of ASTBase | Array(ASTBase) | Nil
  {% end %}
end

# Returns the arrays in the link slots of a node.
private def link_arrays(node : ASTBase) : Array(Array(ASTBase))
  link_slots(node).compact_map(&.as?(Array(ASTBase)))
end

private def vars(prefix, count)
  Array.new(count) { |index| Var.new("#{prefix}#{index}") }
end

describe "Semantic: bindings" do
  it "unbinds all dependencies of a node and keeps its observers" do
    program = Program.new
    node = UpdateCounter.new
    dependencies = Array.new(SLOTS) { Nop.new }
    observers = Array.new(SLOTS - 1) { Nop.new }

    # Interleave the kinds so that the dependencies spill into an array.
    observers.zip(dependencies) do |observer, dependency|
      observer.bind_to node
      node.bind_to dependency
    end
    node.bind_to dependencies.last
    link_arrays(node).should_not be_empty

    node.unbind_all

    node.dependencies.empty?.should be_true
    dependencies.each do |dependency|
      dependency.type = program.int32
    end
    node.updates.should eq(0)

    node.type = program.char
    observers.each do |observer|
      observer.type.should eq(program.char)
    end
  end

  it "keeps the dependency array when unbinding all dependencies" do
    node = Var.new("node")
    vars("v", SLOTS + 1).each { |dependency| node.bind_to dependency }
    array = link_arrays(node).first

    node.unbind_all
    node.dependencies.empty?.should be_true

    dependency = Var.new("new")
    node.bind_to dependency
    node.dependencies.to_a.should eq([dependency] of ASTNode)
    link_arrays(node).should eq([[dependency]])
    link_arrays(node).first.should be(array)
  end

  it "keeps the dependency array and the order when removing dependencies" do
    node = Var.new("node")
    dependencies = vars("v", SLOTS + 2)
    dependencies.first(SLOTS + 1).each { |dependency| node.bind_to dependency }
    array = link_arrays(node).first

    node.unbind_from dependencies[SLOTS - 1, 2]
    node.dependencies.to_a.should eq(dependencies.first(SLOTS - 1))
    link_arrays(node).first.should be(array)

    node.bind_to dependencies.last
    node.dependencies.to_a.should eq(dependencies.first(SLOTS - 1) + [dependencies.last])
    link_arrays(node).first.should be(array)
  end

  it "releases an empty array only when a node needs its slot" do
    node = Var.new("node")
    vars("v", SLOTS + 1).each { |dependency| node.bind_to dependency }
    array = link_arrays(node).first
    node.unbind_all

    observers = vars("o", SLOTS)
    observers.first(SLOTS - 1).each(&.bind_to(node))
    link_arrays(node).should eq([[] of ASTNode])
    link_arrays(node).first.should be(array)

    observers.last.bind_to node
    link_arrays(node).should be_empty
    link_slots(node).should eq(observers)
    node.dependencies.empty?.should be_true
  end

  it "updates every observer when an observer adds a dependency" do
    program = Program.new
    node = Var.new("node")
    dependency = Var.new("dependency")

    # The dependency takes a slot, so the observers after the first one move.
    hook = UpdateHook.new { node.bind_to dependency }
    counters = Array.new(SLOTS - 1) { UpdateCounter.new }
    hook.bind_to node
    counters.each(&.bind_to(node))

    node.type = program.int32

    node.dependencies.to_a.should eq([dependency] of ASTNode)
    counters.map(&.updates).should eq(Array.new(SLOTS - 1, 1))
  end

  it "keeps the observer array when a dependency needs its slot" do
    node = Var.new("node")
    observers = vars("o", SLOTS + 1)
    observers.each(&.bind_to(node))
    array = link_arrays(node).first

    dependency = Var.new("new")
    node.bind_to dependency

    node.dependencies.to_a.should eq([dependency] of ASTNode)
    link_arrays(node).should eq([observers[SLOTS - 2..]])
    link_arrays(node).first.should be(array)
  end

  it "stores the enclosing call in the last slot" do
    node = Var.new("node")
    call = Call.new("foo")
    node.set_enclosing_call call

    node.enclosing_call.should be(call)
    link_slots(node).last.should be(call)
    node.dependencies.empty?.should be_true

    # The dependencies share the slots before the call.
    dependencies = vars("v", SLOTS)
    dependencies.each { |dependency| node.bind_to dependency }
    node.dependencies.to_a.should eq(dependencies)
    link_arrays(node).should eq([dependencies[SLOTS - 2..]])
    node.enclosing_call.should be(call)
  end

  it "frees the last slot for the enclosing call" do
    node = Var.new("node")
    dependencies = vars("v", SLOTS)
    dependencies.each { |dependency| node.bind_to dependency }
    link_arrays(node).should be_empty

    call = Call.new("foo")
    node.set_enclosing_call call

    node.enclosing_call.should be(call)
    node.dependencies.to_a.should eq(dependencies)
    link_arrays(node).should eq([dependencies[SLOTS - 2..]])
  end

  it "frees the last slot when the slots before it hold the other kind" do
    program = Program.new
    node = Var.new("node")
    observers = Array.new(SLOTS - 1) { UpdateCounter.new }
    observers.each(&.bind_to(node))
    dependency = Var.new("dependency")
    node.bind_to dependency

    call = Call.new("foo")
    node.set_enclosing_call call
    node.remove_enclosing_call call

    node.enclosing_call.should be_nil
    node.dependencies.to_a.should eq([dependency] of ASTNode)
    link_arrays(node).should eq([observers[SLOTS - 3..]])
    node.type = program.int32
    observers.map(&.updates).should eq(Array.new(SLOTS - 1, 1))
  end

  it "releases an empty array for the enclosing call" do
    node = Var.new("node")
    vars("v", SLOTS + 1).each { |dependency| node.bind_to dependency }
    node.unbind_all
    observers = vars("o", SLOTS - 1)
    observers.each(&.bind_to(node))
    link_arrays(node).should eq([[] of ASTNode])

    call = Call.new("foo")
    node.set_enclosing_call call

    node.enclosing_call.should be(call)
    link_arrays(node).should be_empty
    link_slots(node).should eq(observers + [call])
  end

  it "gives the slot back when the enclosing call is removed" do
    node = Var.new("node")
    call = Call.new("foo")
    node.set_enclosing_call call
    node.remove_enclosing_call Call.new("bar")
    node.enclosing_call.should be(call)

    node.remove_enclosing_call call
    node.enclosing_call.should be_nil

    dependencies = vars("v", SLOTS)
    dependencies.each { |dependency| node.bind_to dependency }
    link_slots(node).should eq(dependencies)
  end

  it "updates every observer when an observer sets the enclosing call" do
    program = Program.new
    node = Var.new("node")
    call = Call.new("foo")

    # Setting the call merges the two observers into one slot. The second
    # observer removes the call again, which would be recalculated otherwise.
    first = UpdateHook.new { node.set_enclosing_call call }
    second = UpdateHook.new { node.remove_enclosing_call call }
    first.bind_to node
    second.bind_to node
    dependencies = vars("v", SLOTS - 2)
    dependencies.each { |dependency| node.bind_to dependency }

    node.type = program.int32

    first.updates.should eq(1)
    second.updates.should eq(1)
    node.enclosing_call.should be_nil
    node.dependencies.to_a.should eq(dependencies)
  end

  it "binds a node that has no location" do
    program = Program.new
    var = Var.new("x").at(Location.new("foo.cr", 1, 2))
    filtered = var.filtered_by(TruthyFilter.instance)
    filtered.should_not be_a(ASTNode)

    target = UpdateCounter.new
    target.bind_to filtered
    var.type = program.nilable(program.int32)

    filtered.type.should eq(program.int32)
    target.type.should eq(program.int32)
    target.dependencies.to_a.should eq([filtered])
  end

  it "raises without a location for a node that has none" do
    filtered = Var.new("x").at(Location.new("foo.cr", 1, 2)).filtered_by(TruthyFilter.instance)

    error = expect_raises(Crystal::TypeException, "oops") do
      filtered.raise "oops"
    end
    error.line_number.should be_nil
  end

  release_bindings_code = <<-CRYSTAL
    def foo(x)
      while x
        y = 1
        x = false
      end
      y
    end

    a = foo(true)
    b = a ? 1 : 0
    CRYSTAL

  it "releases the links and visitors of a typed program and keeps what codegen reads" do
    result = semantic(release_bindings_code)
    program = result.program
    program.release_bindings = true
    program.release_visitors = true
    typed_def = program.def_instances.values.find!(&.name.== "foo")
    vars = program.vars.values + typed_def.vars.not_nil!.values
    nilable = vars.select(&.dependencies.any?(&.same?(program.nil_var)))
    nilable.map(&.name).should eq(["y"])
    call = result.node.as(Expressions).expressions.compact_map(&.as?(Assign).try(&.value.as?(Call))).first
    call.parent_visitor?.should_not be_nil

    program.release_bindings(result.node)

    call.parent_visitor?.should be_nil

    vars.each do |var|
      var.dependencies.should be_empty
      var.bound_to_nil_var?.should eq(nilable.includes?(var))
    end
    typed_def.dependencies.should be_empty
    typed_def.body.dependencies.should be_empty
  end

  {% for flags in [{false, false}, {true, false}, {false, true}] %}
    it "releases the links: {{flags[0]}}, the visitors: {{flags[1]}}" do
      result = semantic(release_bindings_code)
      program = result.program
      program.release_bindings = {{flags[0]}}
      program.release_visitors = {{flags[1]}}
      typed_def = program.def_instances.values.find!(&.name.== "foo")
      call = result.node.as(Expressions).expressions.compact_map(&.as?(Assign).try(&.value.as?(Call))).first

      program.release_bindings(result.node)

      typed_def.dependencies.empty?.should eq({{flags[0]}})
      program.vars["a"].dependencies.empty?.should eq({{flags[0]}})
      call.parent_visitor?.nil?.should eq({{flags[1]}})
    end
  {% end %}
end
