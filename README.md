# Chain_.jl

**The following is ONLY a POC.**

The macro `@_` is based on [Chain.jl](https://github.com/jkrumbiegel/Chain.jl.git) and uses `__` instead of `_` as the placeholder. Borrow functions from [Underscores.jl](https://github.com/c42f/Underscores.jl/) and we can define anonymous functions in the pipe block as expressions of `_` or `_1,_2,...` (or `_₁,_₂,...`).

## Examples

<table>
<tr><th>Chain_.jl</th><th>Chain.jl</th></tr>
<tr>
<td>
      
```julia
@_ [1:5, 4:10] begin
  map(_[end]^2, __)
  filter(isodd, __)
end
```

</td>
<td>

```julia
@chain [1:5, 4:10] begin
  map(x -> x[end]^2, _)
  filter(isodd, _)
end
```

</td>
</tr>

<tr>
<td>
      
```julia
using DataFrames
df = DataFrame(x = [1, 3, 2, 1], y = 1:4)
```

</td>

</tr>
<tr>
<td>
      
```julia
@_ df begin
    filter(_.x > 1 && isodd(_.y) , __)
    transform([:x, :y] => ByRow(_1 *100 + _2) => :z)
end
```

</td>
<td>

```julia
@chain df begin
    filter(row -> row.x > 1 && isodd(row.y) , _)
    transform([:x, :y] => ByRow((a, b) -> a *100 + b) => :z)
end
```

</td>
</tr>
</table>

