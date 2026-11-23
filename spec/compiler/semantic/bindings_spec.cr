require "../../spec_helper"

private SLOTS = Crystal::ASTNode::LINK_SLOTS

private class UpdateCounter < Crystal::Nop
  getter updates = 0

  def update(from = nil)
    @updates += 1
    super
  end
end

# Runs a block the first time it is updated.
private class UpdateHook < Crystal::Nop
  def initialize(&@hook : ->)
  end

  def update(from = nil)
    if hook = @hook
      @hook = nil
      hook.call
    end
  end
end

# Returns the link slots of a node.
private def link_slots(node : ASTNode) : Array(ASTNode | Array(ASTNode) | Nil)
  {% begin %}
    [{% for index in 0...Crystal::ASTNode::LINK_SLOTS %} node.@link{{index}}, {% end %}] of ASTNode | Array(ASTNode) | Nil
  {% end %}
end

# Returns the arrays in the link slots of a node.
private def link_arrays(node : ASTNode) : Array(Array(ASTNode))
  link_slots(node).compact_map(&.as?(Array(ASTNode)))
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
end
