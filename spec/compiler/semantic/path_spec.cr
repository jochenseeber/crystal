require "../../spec_helper"

describe "Semantic: path" do
  it "has the same names with a single name given as a string or as an array" do
    path = Crystal::Path.new("Foo")
    path.names.to_a.should eq(["Foo"])
    path.should eq(Crystal::Path.new(["Foo"]))
    path.hash.should eq(Crystal::Path.new(["Foo"]).hash)
    path.should_not eq(Crystal::Path.new("Foo", global: true))
    path.single?("Foo").should be_true
    path.single_name?.should eq("Foo")
  end

  it "keeps several names" do
    path = Crystal::Path.new(["Foo", "Bar", "Baz"])
    path.names.to_a.should eq(["Foo", "Bar", "Baz"])
    path.names.size.should eq(3)
    path.names.last.should eq("Baz")
    path.should eq(Crystal::Path.new(["Foo", "Bar", "Baz"]))
    path.should_not eq(Crystal::Path.new("Foo", "Bar"))
    path.single?("Foo").should be_false
    path.to_s.should eq("Foo::Bar::Baz")
  end

  it "clones its names" do
    Crystal::Path.new("Foo").clone.names.to_a.should eq(["Foo"])
    Crystal::Path.new("Foo", "Bar", global: true).clone.should eq(Crystal::Path.global(["Foo", "Bar"]))
  end

  it "resolves to a constant, a type or a replacement" do
    program = Program.new
    const = Const.new(program, program, "FOO", NumberLiteral.new(1))
    replacement = NumberLiteral.new(2)
    path = Crystal::Path.new("FOO")

    path.target_const.should be_nil
    path.target_type.should be_nil
    path.syntax_replacement.should be_nil

    path.target_const = const
    path.target_const.should be(const)
    path.target_type.should be_nil
    path.syntax_replacement.should be_nil

    path.target_type = program.int32
    path.target_const.should be_nil
    path.target_type.should be(program.int32)
    path.syntax_replacement.should be_nil

    path.syntax_replacement = replacement
    path.target_const.should be_nil
    path.target_type.should be_nil
    path.syntax_replacement.should be(replacement)
  end
end
