module Chain_

export @_

is_aside(x) = false
is_aside(x::Expr) = x.head == :macrocall && x.args[1] == Symbol("@aside")


insert_first_arg(symbol::Symbol, firstarg) = Expr(:call, symbol, firstarg)
insert_first_arg(any, firstarg) = error("Can't insert an argument to $any. Needs to be a Symbol or a call expression")

function insert_first_arg(e::Expr, firstarg)

    # f(a, b) --> f(firstarg, a, b)
    if e.head == :call && length(e.args) > 1
        Expr(e.head, e.args[1], firstarg, e.args[2:end]...)

    # @. somesymbol --> somesymbol.(firstarg)
    elseif e.head == :macrocall && length(e.args) == 3 && e.args[1] == Symbol("@__dot__") &&
            e.args[2] isa LineNumberNode && e.args[3] isa Symbol
        Expr(:., e.args[3], Expr(:tuple, firstarg))

    # @macro(a, b) --> @macro(firstarg, a, b)
    elseif e.head == :macrocall && e.args[1] isa Symbol && e.args[2] isa LineNumberNode
        Expr(e.head, e.args[1], e.args[2], firstarg, e.args[3:end]...)

    else
        error("Can't prepend first arg to expression $e that isn't a call.")
    end
end

function rewrite(expr, replacement)
    aside = is_aside(expr)
    if aside
        length(expr.args) != 3 && error("Malformed @aside macro")
        expr = expr.args[3] # 1 is macro symbol, 2 is LineNumberNode
    end

    had_underscore, new_expr = replace_underscores(expr, replacement)

    if !aside
        if !had_underscore
            new_expr = insert_first_arg(new_expr, replacement)
        end
        replacement = gensym()
        new_expr = Expr(Symbol("="), replacement, new_expr)
    end
    
    (new_expr, replacement)
end

rewrite(l::LineNumberNode, replacement) = (l, replacement)

function rewrite_chain_block(firstpart, block)
    if !(block isa Expr && block.head == :block)
        error("Second argument of @chain must be a begin / end block")
    end

    block_expressions = block.args
    isempty(block_expressions) && error("No expressions found in chain block.")

    rewritten_exprs = []
    replacement = firstpart

    for expr in block_expressions
        rewritten, replacement = rewrite(expr, replacement)
        push!(rewritten_exprs, rewritten)
    end

    result = Expr(:let, Expr(:block), Expr(:block, rewritten_exprs...))

    :($(esc(result)))
end

macro chain(firstpart, block)
    rewrite_chain_block(firstpart, block)
end

function replace_underscores(expr::Expr, replacement)
    found_underscore = false

    # if a @chain macrocall is found, only its first arg can be replaced if it's an
    # underscore, otherwise the macro insides are left untouched
    if expr.head == :macrocall && expr.args[1] == Symbol("@chain")
        length(expr.args) != 4 && error("Malformed nested @chain macro")
        expr.args[2] isa LineNumberNode || error("Malformed nested @chain macro")
        arg3 = if expr.args[3] == Symbol("__")
            found_underscore = true
            replacement
        else
            expr.args[3]
        end
        newexpr = Expr(:macrocall, Symbol("@chain"), expr.args[2], arg3, expr.args[4])
    # for all other expressions, their arguments are checked for underscores recursively
    # and replaced if any are found
    else
        newargs = map(x -> replace_underscores(x, replacement), expr.args)
        found_underscore = any(first.(newargs))
        newexpr = Expr(expr.head, last.(newargs)...)
    end
    return found_underscore, newexpr
end

function replace_underscores(x, replacement)
    if x == Symbol("__")
        true, replacement
    else
        false, x
    end
end

"""
    @_ firstpart block

Borrow functions from [Underscores.jl](https://github.com/c42f/Underscores.jl/) and anonymous
functions can be written as expressions of `_` or `_1,_2,...` (or `_₁,_₂,...`).
"""

macro _(firstpart, block)
    rewrite_chain_block_more(firstpart, block)
end

function rewrite_chain_block_more(firstpart, block)
    if !(block isa Expr && block.head == :block)
        error("Second argument of @chain must be a begin / end block")
    end

    block_expressions = block.args
    isempty(block_expressions) && error("No expressions found in chain block.")

    rewritten_exprs = []
    replacement = firstpart

    for expr in block_expressions
        rewritten, replacement = rewrite(lower_underscores(expr), replacement)
        push!(rewritten_exprs, rewritten)
    end

    result = Expr(:let, Expr(:block), Expr(:block, rewritten_exprs...))

    :($(esc(result)))
end

isquoted(ex) = ex isa Expr && ex.head in (:quote, :inert, :meta)

function _replacesyms(sym_map, ex)
    if ex isa Symbol
        return sym_map(ex)
    elseif ex isa Expr
        if isquoted(ex)
            return ex
        end
        args = map(e->_replacesyms(sym_map, e), ex.args)
        return Expr(ex.head, args...)
    else
        return ex
    end
end

function add_closures(ex, prefix, pattern)
    if ex isa Expr && (ex.head == :kw || ex.head == :parameters)
        return Expr(ex.head, map(e->add_closures(e,prefix,pattern), ex.args)...)
    end
    plain_nargs = false
    numbered_nargs = 0
    body = _replacesyms(ex) do sym
        m = match(pattern, string(sym))
        if m === nothing
            sym
        else
            argnum_str = m[1]
            if isempty(argnum_str)
                plain_nargs = true
                argnum = 1
            else
                if !isdigit(argnum_str[1])
                    argnum_str = map(c->c-'₀'+'0', argnum_str)
                end
                argnum = parse(Int, argnum_str)
                numbered_nargs = max(numbered_nargs, argnum)
            end
            Symbol(prefix, argnum)
        end
    end
    if plain_nargs && numbered_nargs > 0
        throw(ArgumentError("Cannot mix plain and numbered `$prefix` placeholders in `$ex`"))
    end
    nargs = max(plain_nargs, numbered_nargs)
    if nargs == 0
        return ex
    end
    argnames = map(i->Symbol(prefix,i), 1:nargs)
    return :(($(argnames...),) -> $body)
end

replace_(ex)  = add_closures(ex, "_", r"^_([0-9]*|[₀-₉]*)$")

const _square_bracket_ops = [:comprehension, :typed_comprehension, :generator,
                             :ref, :vcat, :typed_vcat, :hcat, :typed_hcat, :row]
                             
_isoperator(x) = x isa Symbol && Base.isoperator(x)

function lower_inner(ex)
    if ex isa Expr
        if ex.head == :(=) ||
            (ex.head == :call && length(ex.args) > 1 &&
                (_isoperator(ex.args[1]) || 
                    (ex.args[2] isa Expr && ex.args[2].args[1] == Symbol("=>"))
                )
            )
            # Infix operators do not count as outermost function call
            return Expr(ex.head, ex.args[1],
                map(lower_inner, ex.args[2:end])...)
        elseif ex.head in _square_bracket_ops || ex.head == :if
            # Indexing & other square brackets not counted as outermost function
            return Expr(ex.head, map(lower_inner, ex.args)...)
        elseif ex.head == :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
            # Getproperty also doesn't count
            return Expr(ex.head, map(lower_inner, ex.args)...)
        elseif ex.head == :. && length(ex.args) == 2 &&
            ex.args[2] isa Expr && ex.args[2].head == :tuple
            # Broadcast calls treated as normal calls for underscore lowering
            return Expr(ex.head, replace_(ex.args[1]),
                                  Expr(:tuple, map(replace_, ex.args[2].args)...))
        else
            # For other syntax, replace _ in args individually
            return Expr(ex.head, map(replace_, ex.args)...)
        end
    else
        return ex
    end
end

const _pipeline_ops = [:|>, :<|, :∘, :.|>, :.<|]

function lower_underscores(ex)
    if ex isa Expr
        if isquoted(ex)
            return ex
        elseif ex.head == :call && length(ex.args) > 1 &&
               ex.args[1] in _pipeline_ops
            # Special case for pipelining and composition operators
            return Expr(ex.head, ex.args[1],
                        map(lower_underscores, ex.args[2:end])...)
        elseif ex.head == :do
            error("@_ expansion for `do` syntax is reserved")
        else
            # For other syntax, replace __ over the entire expression
            return lower_inner(ex)
        end
    else
        return ex
    end
end

end
