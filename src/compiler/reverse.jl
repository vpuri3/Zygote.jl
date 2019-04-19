using IRTools: IR, Variable, Argument, Pipe, xcall, arg, var, prewalk, postwalk,
  blocks, predecessors, successors, argument!, arguments, branches, argmap,
  exprtype, insertafter!, finish, allspats!, trimspats!, substitute!, substitute,
  block, block!, branch!, return!
using Base: @get!

@inline tuple_va(N, xs) = xs
@inline tuple_va(N, x, xs...) = (x, tuple_va(N, xs...)...)
@inline tuple_va(::Val{N}, ::Nothing) where N = ntuple(_ -> nothing, Val(N))

iscall(x, m::Module, n::Symbol) = isexpr(x, :call) && x.args[1] == GlobalRef(m, n)

gradindex(x, i) = x[i]
gradindex(::Nothing, i) = nothing
xgetindex(x, i...) = xcall(Base, :getindex, x, i...)
xgradindex(x, i) = xcall(Zygote, :gradindex, x, i)

normalise!(ir) = ir |> IRTools.merge_entry! |> IRTools.merge_returns!

function instrument_new!(ir, v, ex)
  isexpr(ex, :new) ? (ir[v] = xcall(Zygote, :__new__, ex.args...)) :
  isexpr(ex, :splatnew) ? (ir[v] = xcall(Zygote, :__splatnew__, ex.args...)) :
  ex
end

# Hack to work around fragile constant prop through overloaded functions
is_literal_getproperty(ex) =
  (iscall(ex, Base, :getproperty) || iscall(ex, Core, :getfield)) &&
  ex.args[3] isa QuoteNode

function instrument_getproperty!(ir, v, ex)
  is_literal_getproperty(ex) ?
    (ir[v] = xcall(Zygote, :literal_getproperty, ex.args[2], Val(ex.args[3].value))) :
    ex
end

function istrackable(x)
  x isa GlobalRef && x.mod ∉ (Base, Core) || return false
  isconst(x.mod, x.name) || return true
  x = getfield(x.mod, x.name)
  !(x isa Type || sizeof(x) == 0)
end

function instrument_global!(ir, v, ex)
  if istrackable(ex)
    ir[v] = xcall(Zygote, :unwrap, QuoteNode(ex), ex)
  else
    ir[v] = prewalk(ex) do x
      istrackable(x) || return x
      insert!(ir, v, xcall(Zygote, :unwrap, QuoteNode(x), x))
    end
  end
end

function instrument(ir::IR)
  pr = Pipe(ir)
  for v in pr
    ex = ir[v].expr
    ex = instrument_new!(pr, v, ex)
    ex = instrument_getproperty!(pr, v, ex)
    ex = instrument_global!(pr, v, ex)
  end
  return finish(pr)
end

const BranchNumber = UInt8

function record_branches!(ir::IR)
  brs = Dict{Int,Variable}()
  for bb in blocks(ir)
    preds = predecessors(bb)
    length(preds) > 1 || continue
    brs[bb.id] = argument!(bb)
    i = length(arguments(bb))
    n = 0
    for aa in blocks(ir), br in branches(aa)
      br.block == bb.id && (arguments(br)[i] = BranchNumber(n += 1))
    end
  end
  return ir, brs
end

ignored_f(f) = f in (GlobalRef(Base, :not_int),
                     GlobalRef(Core.Intrinsics, :not_int),
                     GlobalRef(Core, :(===)),
                     GlobalRef(Core, :apply_type),
                     GlobalRef(Core, :typeof),
                     GlobalRef(Core, :throw),
                     GlobalRef(Base, :kwerr),
                     GlobalRef(Core, :kwfunc),
                     GlobalRef(Core, :isdefined))
ignored_f(ir, f) = ignored_f(f)
ignored_f(ir, f::Variable) = ignored_f(ir[f])

ignored(ir, ex) = isexpr(ex, :call) && ignored_f(ir, ex.args[1])
ignored(ir, ex::Variable) = ignored(ir, ir[ex])

# TODO: remove this once we don't mess with type inference
function _forward_type(Ts)
  usetyped || return Any
  all(T -> isconcretetype(T) || T <: DataType, Ts) || return Any
  T = Core.Compiler.return_type(_forward, Tuple{Context,Ts...})
  return T == Union{} ? Any : T
end

isvalidtype(jT, yT) = jT <: Tuple && length(jT.parameters) == 2 && jT.parameters[1] <: yT

function primal(ir::IR)
  pr = Pipe(ir)
  pbs = Dict{Variable,Variable}()
  for i = 0:length(ir.args)
    substitute!(pr, arg(i), arg(i+2))
  end
  for v in pr
    ex = ir[v].expr
    if isexpr(ex, :call) && !ignored(ir, ex)
      # yT = exprtype(ir, v)
      # T = _forward_type(exprtype.(Ref(ir), ex.args))
      # if yT == Any || isvalidtype(T, yT)
        yJ = insert!(pr, v, xcall(Zygote, :_forward, Argument(0), ex.args...))
        pr[v] = xgetindex(yJ, 1)
        # bT = T == Any ? Any : T.parameters[2]
        pbs[v] = insertafter!(pr, v, xgetindex(yJ, 2))
      # else
      #   yJ = insert_node!(ir, i, Any, xcall(Zygote, :_forward, Argument(2), ex.args...))
      #   y =  insert_node!(ir, i, Any, xgetindex(yJ, 1))
      #   J =  insert_node!(ir, i, Any, xgetindex(yJ, 2))
      #   ir[v] = xcall(Zygote, :typeassert, y, yT)
      # end
    end
  end
  pr = finish(pr)
  pushfirst!(pr.args, typeof(_forward), Context)
  pr, brs = record_branches!(pr)
  return pr, brs, pbs
end

struct Primal
  ir::IR
  pr::IR
  varargs::Union{Int,Nothing}
  branches::Dict{Int,Variable}
  pullbacks::Dict{Variable,Variable}
end

function Primal(ir::IR; varargs = nothing)
  ir = instrument(normalise!(ir))
  pr, brs, pbs = primal(ir)
  Primal(allspats!(ir), pr, varargs, brs, pbs)
end

# Backwards Pass

struct Alpha
  id::Int
end

Base.show(io::IO, x::Alpha) = print(io, "@", x.id)

alpha(x) = x
alpha(x::Variable) = Alpha(x.id)
Variable(a::Alpha) = Variable(a.id)

sig(b::IRTools.Block) = unique([arg for br in branches(b) for arg in br.args if arg isa Union{Argument,Variable}])
sig(pr::Primal) = Dict(b.id => sig(b) for b in blocks(pr.ir))

# TODO unreachables?
function adjointcfg(pr::Primal)
  ir = IR()
  return!(ir, nothing)
  for b in blocks(pr.ir)[2:end]
    block!(ir)
    preds = predecessors(b)
    rb = block(ir, b.id)
    for i = 1:length(preds)
      cond = i == length(preds) ? nothing :
        push!(rb, xcall(Base, :(!==), alpha(pr.branches[b.id]), BranchNumber(i)))
      branch!(rb, preds[i].id, unless = cond)
    end
  end
  sigs = sig(pr)
  for b in blocks(ir)[1:end-1], i = 1:length(sigs[b.id])
    argument!(b)
  end
  argument!(blocks(ir)[end])
  return ir, sigs
end

branchfor(ir, (from,to)) =
  get(filter(br -> br.block == to, branches(block(ir, from))), 1, nothing)

xaccum(ir) = nothing
xaccum(ir, x) = x
xaccum(ir, xs...) = push!(ir, xcall(Zygote, :accum, xs...))

function adjoint(pr::Primal)
  ir, sigs = adjointcfg(pr)
  for b in reverse(blocks(pr.ir))
    rb = block(ir, b.id)
    grads = Dict()
    grad(x, x̄) = push!(get!(grads, x, []), x̄)
    grad(x) = xaccum(rb, get(grads, x, [])...)
    # Backprop through (successor) branch arguments
    for i = 1:length(sigs[b.id])
      grad(sigs[b.id][i], arguments(rb)[i])
    end
    # Backprop through statements
    for v in reverse(keys(b))
      if haskey(pr.pullbacks, v)
        g = push!(rb, Expr(:call, alpha(pr.pullbacks[v]), grad(v)))
        for (i, x) in enumerate(pr.ir[v].expr.args)
          x isa Union{Variable,Argument} || continue
          grad(x, push!(rb, xgradindex(g, i)))
        end
      elseif isexpr(b[v].expr, GlobalRef, :call, :isdefined)
      else # TODO: Pi nodes
        ex = b[v].expr
        desc = isexpr(ex) ? "$(ex.head) expression" : ex
        push!(rb, xcall(Base, :error, "Can't differentiate $desc"))
      end
    end
    if b.id > 1 # Backprop through (predecessor) branch arguments
      gs = grad.(arguments(b))
      for br in branches(rb)
        br′ = branchfor(pr.ir, br.block=>b.id)
        br′ == nothing && continue
        ins = br′.args
        @assert length(unique(ins)) == length(ins)
        for i = 1:length(br.args)
          j = findfirst(x -> x == sigs[br.block][i], ins)
          j == nothing && continue
          br.args[i] = gs[j]
        end
      end
    else # Backprop function arguments
      gs = [grad(arg(i)) for i = 1:length(pr.ir.args)]
      Δ = push!(rb, pr.varargs == nothing ?
                      xcall(Zygote, :tuple, gs...) :
                      xcall(Zygote, :tuple_va, Val(pr.varargs), gs...))
      branches(rb)[1].args[1] = Δ
    end
  end
  return ir
end

struct Adjoint
  primal::IR
  adjoint::IR
end

function Adjoint(ir::IR; varargs = nothing, normalise = true)
  pr = Primal(ir, varargs = varargs)
  adj = adjoint(pr) |> trimspats!
  if normalise
    permute!(adj, length(adj.blocks):-1:1)
    adj = IRTools.domorder!(adj) |> IRTools.renumber
  end
  Adjoint(pr.pr, adj)
end

function pow(x, n)
  r = 1
  while n > 0
    n -= 1
    r *= x
  end
  return r
end
