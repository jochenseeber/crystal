require "../syntax/ast"

module Crystal
  class ASTNode
    def no_returns?
      !!type?.try &.no_return?
    end
  end

  class Def
    # Smaller than a pointer, like the fields after it: they pack with the
    # ones at the end of `Def` in `semantic/ast.cr`.
    property? abi_info : Bool = false

    def mangled_name(program, self_type)
      name = String.build do |str|
        str << '*'

        if owner = @owner
          if owner.metaclass?
            self_type.instance_type.llvm_name(str)
            if original_owner != self_type
              str << '@'
              original_owner.instance_type.llvm_name(str)
            end
            str << "::"
          elsif !owner.is_a?(Crystal::Program)
            self_type.llvm_name(str)
            if original_owner != self_type
              str << '@'
              original_owner.llvm_name(str)
            end
            str << '#'
          end
        end

        str << self.name.gsub('@', '.')

        next_def = self.next
        while next_def
          str << '\''
          next_def = next_def.next
        end

        if args.size > 0 || uses_block_arg?
          str << '<'
          if args.size > 0
            args.each_with_index do |arg, i|
              str << ", " if i > 0
              arg.type.llvm_name(str)
            end
          end
          if uses_block_arg?
            str << ", " if args.size > 0
            str << '&'
            block_arg.not_nil!.type.llvm_name(str)
          end
          str << '>'
        end
        if return_type = @type
          str << ':'
          return_type.llvm_name(str)
        end
      end

      Crystal.safe_mangling(program, name)
    end

    def varargs?
      false
    end

    def call_convention
      nil
    end

    # :nodoc:
    # Whether this def must respect the C calling convention, stored in a
    # single byte instead of a 16-byte `Bool?` union.
    enum CCallingConvention : UInt8
      Unknown
      No
      Yes
    end

    @c_calling_convention : CCallingConvention = CCallingConvention::Unknown

    # Whether this def must respect the C calling convention, or `nil` if
    # that is not known yet.
    def c_calling_convention : Bool?
      case @c_calling_convention
      in .unknown? then nil
      in .no?      then false
      in .yes?     then true
      end
    end

    def c_calling_convention=(value : Bool?) : Bool?
      @c_calling_convention =
        case value
        in Nil   then CCallingConvention::Unknown
        in false then CCallingConvention::No
        in true  then CCallingConvention::Yes
        end
      value
    end

    # Returns `self` as an `External` if this Def is an External
    # that must respect the C calling convention.
    def c_calling_convention?
      if @c_calling_convention.unknown?
        self.c_calling_convention = compute_c_calling_convention
      end

      @c_calling_convention.yes? ? self : nil
    end

    def llvm_intrinsic?
      self.is_a?(External) && self.real_name.starts_with?("llvm.")
    end

    private def compute_c_calling_convention
      # One case where this is not true if for LLVM intrinsics.
      # For example overflow intrinsics return a tuple, like {i32, i1}:
      # in C ABI that is represented as i64, but we need to keep the original
      # type here, respecting LLVM types, not the C ABI.
      if self.is_a?(External)
        return !self.real_name.starts_with?("llvm.")
      end

      # Another case is when an argument is an external struct, in which
      # case we must respect the C ABI (this applies to Crystal methods
      # and procs too)

      # Only applicable to procs (no owner) for now
      owner = @owner
      if owner
        return false
      end

      proc_c_calling_convention?
    end

    def proc_c_calling_convention?
      # We use C ABI if:
      # - all arguments are allowed in lib calls (because then it can be passed to C)
      # - at least one argument type, or the return type, is an extern struct
      found_extern = false

      if (type = self.type?)
        type = type.remove_alias
        if type.extern?
          found_extern = true
        elsif !type.void? && !type.nil_type? && !type.allowed_in_lib?
          return false
        end
      end

      args.each do |arg|
        arg_type = arg.type.remove_alias
        if arg_type.extern?
          found_extern = true
        elsif !arg_type.allowed_in_lib?
          return false
        end
      end

      found_extern
    end
  end

  class Asm
    def dialect : LLVM::InlineAsmDialect
      intel? ? LLVM::InlineAsmDialect::Intel : LLVM::InlineAsmDialect::ATT
    end
  end
end
