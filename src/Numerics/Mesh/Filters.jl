module Filters

using LinearAlgebra, GaussQuadrature, KernelAbstractions
using ..Grids
using ..Grids: Direction, EveryDirection, HorizontalDirection, VerticalDirection

export AbstractSpectralFilter, AbstractFilter
export ExponentialFilter, CutoffFilter, TMARFilter

abstract type AbstractFilter end
abstract type AbstractSpectralFilter <: AbstractFilter end

"""
    spectral_filter_matrix(r, Nc, σ)

Returns the filter matrix that takes function values at the interpolation
`N+1` points, `r`, converts them into Legendre polynomial basis coefficients,
multiplies
```math
σ((n-N_c)/(N-N_c))
```
against coefficients `n=Nc:N` and evaluates the resulting polynomial at the
points `r`.
"""
function spectral_filter_matrix(r, Nc, σ)
    N = length(r) - 1
    T = eltype(r)

    @assert N >= 0
    @assert 0 <= Nc <= N

    a, b = GaussQuadrature.legendre_coefs(T, N)
    V = GaussQuadrature.orthonormal_poly(r, a, b)

    Σ = ones(T, N + 1)
    Σ[(Nc:N) .+ 1] .= σ.(((Nc:N) .- Nc) ./ (N - Nc))

    V * Diagonal(Σ) / V
end

"""
    ExponentialFilter(grid, Nc=0, s=32, α=-log(eps(eltype(grid))))

Returns the spectral filter with the filter function
```math
σ(η) = \exp(-α η^s)
```
where `s` is the filter order (must be even), the filter starts with
polynomial order `Nc`, and `alpha` is a parameter controlling the smallest
value of the filter function.
"""
struct ExponentialFilter <: AbstractSpectralFilter
    "filter matrix"
    filter

    function ExponentialFilter(
        grid,
        Nc = 0,
        s = 32,
        α = -log(eps(eltype(grid))),
    )
        AT = arraytype(grid)
        N = polynomialorder(grid)
        ξ = referencepoints(grid)

        @assert iseven(s)
        @assert 0 <= Nc <= N

        σ(η) = exp(-α * η^s)
        filter = spectral_filter_matrix(ξ, Nc, σ)

        new(AT(filter))
    end
end

"""
    CutoffFilter(grid, Nc=polynomialorder(grid))

Returns the spectral filter that zeros out polynomial modes greater than or
equal to `Nc`.
"""
struct CutoffFilter <: AbstractSpectralFilter
    "filter matrix"
    filter

    function CutoffFilter(grid, Nc = polynomialorder(grid))
        AT = arraytype(grid)
        ξ = referencepoints(grid)

        σ(η) = 0
        filter = spectral_filter_matrix(ξ, Nc, σ)

        new(AT(filter))
    end
end

"""
    TMARFilter()

Returns the truncation and mass aware rescaling nonnegativity preservation
filter.  The details of this filter are described in

    @article{doi:10.1175/MWR-D-16-0220.1,
      author = {Light, Devin and Durran, Dale},
      title = {Preserving Nonnegativity in Discontinuous Galerkin
               Approximations to Scalar Transport via Truncation and Mass
               Aware Rescaling (TMAR)},
      journal = {Monthly Weather Review},
      volume = {144},
      number = {12},
      pages = {4771-4786},
      year = {2016},
      doi = {10.1175/MWR-D-16-0220.1},
    }

Note this needs to be used with a restrictive time step or a flux correction
to ensure that grid integral is conserved.

## Examples

This filter can be applied to the 3rd and 4th fields of an `MPIStateArray` `Q`
with the code

```julia
Filters.apply!(Q, (3, 4), grid, TMARFilter())
```

where `grid` is the associated `DiscontinuousSpectralElementGrid`.
"""
struct TMARFilter <: AbstractFilter end

"""
    apply!(Q, states, grid::DiscontinuousSpectralElementGrid,
           filter::AbstractSpectralFilter,
           direction::Direction = EveryDirection())

Applies `filter` to the `states` of `Q`.

The `direction` argument controls if the filter is applied in the horizontal
and/or vertical directions. It is assumed that the trailing dimension on the
reference element is the vertical dimension and the rest are horizontal.
"""
function apply!(
    Q,
    states,
    grid::DiscontinuousSpectralElementGrid,
    filter::AbstractSpectralFilter,
    direction::Direction = EveryDirection(),
)
    topology = grid.topology

    dim = dimensionality(grid)
    N = polynomialorder(grid)

    nstate = size(Q, 2)

    filtermatrix = filter.filter
    device = typeof(Q.data) <: Array ? CPU() : CUDA()

    nelem = length(topology.elems)
    Nq = N + 1
    Nqk = dim == 2 ? 1 : Nq

    nrealelem = length(topology.realelems)

    event = Event(device)
    event = kernel_apply_filter!(device, (Nq, Nq, Nqk))(
        Val(dim),
        Val(N),
        Val(nstate),
        Val(direction),
        Q.data,
        Val(states),
        filtermatrix,
        topology.realelems;
        ndrange = (nrealelem * Nq, Nq, Nqk),
        dependencies = (event,),
    )
    wait(device, event)
end

"""
    apply!(Q, states, grid::DiscontinuousSpectralElementGrid, ::TMARFilter)

Applies the truncation and mass aware rescaling to `states` of `Q`.  This
rescaling keeps the states nonegative while keeping the element average
the same.
"""
function apply!(Q, states, grid::DiscontinuousSpectralElementGrid, ::TMARFilter)
    topology = grid.topology

    device = typeof(Q.data) <: Array ? CPU() : CUDA()

    dim = dimensionality(grid)
    N = polynomialorder(grid)
    Nq = N + 1
    Nqk = dim == 2 ? 1 : Nq

    nrealelem = length(topology.realelems)
    nreduce = 2^ceil(Int, log2(Nq * Nqk))

    event = Event(device)
    event = kernel_apply_TMAR_filter!(device, (Nq, Nqk), (nrealelem * Nq, Nqk))(
        Val(nreduce),
        Val(dim),
        Val(N),
        Q.data,
        Val(states),
        grid.vgeo,
        topology.realelems;
        dependencies = (event,),
    )
    wait(device, event)
end

using ..Mesh.Grids: EveryDirection, VerticalDirection, HorizontalDirection
using KernelAbstractions.Extras: @unroll

const _M = Grids._M

@doc """
    kernel_apply_filter!(::Val{dim}, ::Val{N}, ::Val{nstate}, ::Val{direction},
                      Q, ::Val{states}, filtermatrix,
                      elems) where {dim, N, nstate, states, direction}

Computational kernel: Applies the `filtermatrix` to the `states` of `Q`.

The `direction` argument is used to control if the filter is applied in the
horizontal and/or vertical reference directions.
""" kernel_apply_filter!
@kernel function kernel_apply_filter!(
    ::Val{dim},
    ::Val{N},
    ::Val{nstate},
    ::Val{direction},
    Q,
    ::Val{states},
    filtermatrix,
    elems,
) where {dim, N, nstate, direction, states}
    @uniform begin
        FT = eltype(Q)

        Nq = N + 1
        Nqk = dim == 2 ? 1 : Nq

        if direction isa EveryDirection
            filterinξ1 = filterinξ2 = true
            filterinξ3 = dim == 2 ? false : true
        elseif direction isa HorizontalDirection
            filterinξ1 = true
            filterinξ2 = dim == 2 ? false : true
            filterinξ3 = false
        elseif direction isa VerticalDirection
            filterinξ1 = false
            filterinξ2 = dim == 2 ? true : false
            filterinξ3 = dim == 2 ? false : true
        end

        nfilterstates = length(states)
    end

    s_filter = @localmem FT (Nq, Nq)
    s_Q = @localmem FT (Nq, Nq, Nqk, nfilterstates)
    l_Qfiltered = @private FT (nfilterstates,)

    e = @index(Group, Linear)
    i, j, k = @index(Local, NTuple)

    @inbounds begin
        s_filter[i, j] = filtermatrix[i, j]

        @unroll for fs in 1:nfilterstates
            l_Qfiltered[fs] = zero(FT)
        end

        ijk = i + Nq * ((j - 1) + Nq * (k - 1))

        @unroll for fs in 1:nfilterstates
            s_Q[i, j, k, fs] = Q[ijk, states[fs], e]
        end

        if filterinξ1
            @synchronize
            @unroll for n in 1:Nq
                @unroll for fs in 1:nfilterstates
                    l_Qfiltered[fs] += s_filter[i, n] * s_Q[n, j, k, fs]
                end
            end

            if filterinξ2 || filterinξ3
                @synchronize
                @unroll for fs in 1:nfilterstates
                    s_Q[i, j, k, fs] = l_Qfiltered[fs]
                    l_Qfiltered[fs] = zero(FT)
                end
            end
        end

        if filterinξ2
            @synchronize
            @unroll for n in 1:Nq
                @unroll for fs in 1:nfilterstates
                    l_Qfiltered[fs] += s_filter[j, n] * s_Q[i, n, k, fs]
                end
            end

            if filterinξ3
                @synchronize
                @unroll for fs in 1:nfilterstates
                    s_Q[i, j, k, fs] = l_Qfiltered[fs]
                    l_Qfiltered[fs] = zero(FT)
                end
            end
        end

        if filterinξ3
            @synchronize
            @unroll for n in 1:Nqk
                @unroll for fs in 1:nfilterstates
                    l_Qfiltered[fs] += s_filter[k, n] * s_Q[i, j, n, fs]
                end
            end
        end

        # Store result
        ijk = i + Nq * ((j - 1) + Nq * (k - 1))
        @unroll for fs in 1:nfilterstates
            Q[ijk, states[fs], e] = l_Qfiltered[fs]
        end

        @synchronize
    end
end

@kernel function kernel_apply_TMAR_filter!(
    ::Val{nreduce},
    ::Val{dim},
    ::Val{N},
    Q,
    ::Val{filterstates},
    vgeo,
    elems,
) where {nreduce, dim, N, filterstates}
    @uniform begin
        FT = eltype(Q)

        Nq = N + 1
        Nqj = dim == 2 ? 1 : Nq

        nfilterstates = length(filterstates)
        nelemperblock = 1
    end

    l_Q = @private FT (nfilterstates, Nq)
    l_MJ = @private FT (Nq,)

    s_MJQ = @localmem FT (Nq * Nqj, nfilterstates)
    s_MJQclipped = @localmem FT (Nq * Nqj, nfilterstates)

    e = @index(Group, Linear)
    i, j = @index(Local, NTuple)

    @inbounds begin
        # loop up the pencil and load Q and MJ
        @unroll for k in 1:Nq
            ijk = i + Nq * ((j - 1) + Nqj * (k - 1))

            @unroll for sf in 1:nfilterstates
                s = filterstates[sf]
                l_Q[sf, k] = Q[ijk, s, e]
            end

            l_MJ[k] = vgeo[ijk, _M, e]
        end

        @unroll for sf in 1:nfilterstates
            MJQ, MJQclipped = zero(FT), zero(FT)

            @unroll for k in 1:Nq
                MJ = l_MJ[k]
                Qs = l_Q[sf, k]
                Qsclipped = Qs ≥ 0 ? Qs : zero(Qs)

                MJQ += MJ * Qs
                MJQclipped += MJ * Qsclipped
            end

            ij = i + Nq * (j - 1)

            s_MJQ[ij, sf] = MJQ
            s_MJQclipped[ij, sf] = MJQclipped
        end
        @synchronize

        @unroll for n in 11:-1:1
            if nreduce ≥ 2^n
                ij = i + Nq * (j - 1)
                ijshift = ij + 2^(n - 1)
                if ij ≤ 2^(n - 1) && ijshift ≤ Nq * Nqj
                    @unroll for sf in 1:nfilterstates
                        s_MJQ[ij, sf] += s_MJQ[ijshift, sf]
                        s_MJQclipped[ij, sf] += s_MJQclipped[ijshift, sf]
                    end
                end
                @synchronize
            end
        end

        @unroll for sf in 1:nfilterstates
            qs_average = s_MJQ[1, sf]
            qs_clipped_average = s_MJQclipped[1, sf]

            r = qs_average > 0 ? qs_average / qs_clipped_average : zero(FT)

            s = filterstates[sf]
            @unroll for k in 1:Nq
                ijk = i + Nq * ((j - 1) + Nqj * (k - 1))

                Qs = l_Q[sf, k]
                Q[ijk, s, e] = Qs ≥ 0 ? r * Qs : zero(Qs)
            end
        end
    end
end

end
