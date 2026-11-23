module Crystal
  class Program
    @bindings_released = false

    # :nodoc:
    #
    # Removes the links between nodes that only the type inference uses
    # (`ASTBase#release_links`) if `#release_bindings?` is set. Called before
    # codegen: once types no longer change, the links only keep alive nodes
    # that nothing else needs, such as `TypeFilteredNode`s and the `MetaVar`s
    # of single branches.
    #
    # The interpreter types code while it runs and never calls this.
    def release_bindings(node : ASTNode) : Nil
      return unless release_bindings?
      return if @bindings_released
      @bindings_released = true

      BindingsReleaser.new(self).release(node)
    end
  end

  # Visits every node that stays alive after semantic and removes its links:
  # the main program, the typed defs of all types, the values of constants
  # and the initializers of class and instance variables, with the variables
  # that belong to each of them.
  class BindingsReleaser < Visitor
    @defs = Set(Def).new.compare_by_identity
    @visitors = Set(MainVisitor).new.compare_by_identity

    def initialize(@program : Program)
    end

    def release(node : ASTNode) : Nil
      node.accept self
      # Observed by every variable that can be nil before an assignment.
      @program.nil_var.release_links
      release_vars @program.vars
      @program.file_modules.each_value do |file_module|
        release_vars file_module.vars?
      end
      @program.class_var_initializers.each do |initializer|
        initializer.node.accept self
        release_vars initializer.meta_vars
      end
      release_type @program
    end

    private def release_type(type : Type) : Nil
      if type.is_a?(NamedType) || type.is_a?(Program) || type.is_a?(FileModule)
        type.types?.try &.each_value do |inner_type|
          release_type inner_type
        end
      end

      if type.is_a?(GenericType)
        type.each_instantiated_type do |instance|
          release_type instance
        end
      end

      release_type type.metaclass if type.metaclass != type

      # Read through the instance variables: the getters create an empty
      # hash for a type that has none.
      if type.is_a?(DefInstanceContainer)
        type.@def_instances.try &.each_value &.accept(self)
      end

      if type.is_a?(InstanceVarContainer)
        type.@instance_vars.try &.each_value &.release_links
      end

      if type.is_a?(ClassVarContainer)
        type.class_vars?.try &.each_value &.release_links
      end

      if type.is_a?(InstanceVarInitializerContainer)
        type.instance_vars_initializers.try &.each do |initializer|
          initializer.value.accept self
          release_vars initializer.meta_vars
        end
      end

      if type.is_a?(Const)
        type.value.accept self
        type.fake_def.try &.accept self
        release_visitor type.visitor
      end
    end

    def visit(node : ASTNode)
      node.release_links
      true
    end

    def visit(node : MetaVar)
      release_var node
      true
    end

    def visit(node : ExpandableNode)
      node.release_links
      node.expanded.try &.accept self
      true
    end

    def visit(node : Def)
      return false unless @defs.add?(node)

      node.release_links
      release_vars node.vars
      true
    end

    def visit(node : Call)
      node.release_links
      node.target_defs.try &.each &.accept(self)
      node.expanded.try &.accept self
      release_vars node.before_vars
      release_visitor node.parent_visitor?
      true
    end

    def visit(node : Block)
      node.release_links
      if binder = node.binder
        binder.release_links
        binder.@yields.each { |_, vars| vars.try &.each &.release_links }
      end
      node.@break.try &.release_links
      node.fun_literal.try &.accept self
      release_vars node.vars
      release_vars node.after_vars
      true
    end

    def visit(node : While)
      node.release_links
      node.break_vars.try &.each { |vars| release_vars vars }
      true
    end

    def visit(node : Yield)
      node.release_links
      node.expanded.try &.accept self
      true
    end

    def visit(node : ProcPointer)
      node.release_links
      node.expanded.try &.accept self
      true
    end

    def visit(node : IsA)
      node.release_links
      node.syntax_replacement.try &.accept self
      true
    end

    private def release_visitor(visitor : MainVisitor?) : Nil
      return unless visitor
      return unless @visitors.add?(visitor)

      release_vars visitor.vars
      release_vars visitor.meta_vars
      release_vars visitor.@while_vars
      visitor.all_exception_handler_vars.try &.each { |vars| release_vars vars }
      visitor.yield_vars.try &.each &.release_links
      visitor.@found_self_in_initialize_call.try &.each &.release_links
      visitor.@used_ivars_in_calls_in_initialize.try &.each_value &.each &.release_links
    end

    private def release_vars(vars : MetaVars?) : Nil
      vars.try &.each_value { |var| release_var var }
    end

    # A variable can be in several hashes: once its links are gone, it keeps
    # the flag it got the first time.
    #
    # Its local variables can be nodes that are no longer in the program,
    # because the cleanup removed them. A local `MetaVar` without links is
    # already released, which ends the recursion.
    private def release_var(var : MetaVar, local = false) : Nil
      var.bound_to_nil_var = true if var.dependencies.any? &.same?(@program.nil_var)
      return unless var.release_links || !local

      var.local_vars?.try &.each do |local_var|
        if local_var.is_a?(MetaVar)
          release_var local_var, local: true
        else
          local_var.release_links
        end
      end
    end
  end
end
