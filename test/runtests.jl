@static if VERSION >= v"1.6"
    # Enzyme only supports Julia >= 1.6
    # We add it without messing with the existing, possibly precompiled, dependencies
    using Pkg
    Pkg.add(Pkg.PackageSpec(; name="Enzyme", uuid="7da242da-08ed-463a-9acd-ee780be4f1d9");
            preserve=Pkg.PRESERVE_ALL)

    import Enzyme
    struct EnzymeTestMode <: Enzyme.Mode end
end

using LogDensityProblems, Test, Distributions, BenchmarkTools
import LogDensityProblems: capabilities, dimension, logdensity
using LogDensityProblems: logdensity_and_gradient, LogDensityOrder

import ForwardDiff, Tracker, Random, Zygote, ReverseDiff
using UnPack: @unpack

####
#### test setup and utilities
####

###
### reproducible randomness
###

Random.seed!(1)

###
### comparisons (for testing)
###

"""
    a ≅ b

Compare log denfields and types, for unit testing.
"""
≅(::Any, ::Any, atol = 0) = false

function ≅(a::Real, b::Real, atol = 0)
    if isnan(a)
        isnan(b)
    elseif isinf(a)
        a == b
    else
        abs(a - b) ≤ atol
    end
end

function ≅(a::Tuple{Real,Any}, b::Tuple{Real,Any}, atol = 0)
    ≅(first(a), first(b), atol) || return false
    !isfinite(first(a)) || isapprox(last(a), last(b); atol = atol, rtol = 0)
end

@testset "comparisons for unit testing" begin
    @test 1 ≅ 1
    @test !(1 ≅ 2)
    @test Inf ≅ Inf
    @test (1, [1, 2]) ≅ (1, [1, 2])
    @test !((1, [1, 2]) ≅ (1, [1, 3]))
    @test !((3, [1, 2]) ≅ (1, [1, 2]))
    @test (-Inf, [1, 2]) ≅ (-Inf, [1, 2])
    @test (-Inf, [1, 2]) ≅ (-Inf, [1, 3])
    @test (-Inf, [1, 2]) ≅ (-Inf, nothing)
end

###
### simple log densities for testing
###

struct TestLogDensity{F}
    ℓ::F
end
logdensity(ℓ::TestLogDensity, x) = ℓ.ℓ(x)
dimension(::TestLogDensity) = 3
test_logdensity1(x) = -2*abs2(x[1]) - 3*abs2(x[2]) - 5*abs2(x[3])
test_logdensity(x) = any(x .< 0) ? -Inf : test_logdensity1(x)
test_gradient(x) = x .* [-4, -6, -10]
TestLogDensity() = TestLogDensity(test_logdensity) # default: -Inf for negative input
Base.show(io::IO, ::TestLogDensity) = print(io, "TestLogDensity")

struct TestLogDensity2 end
logdensity(::TestLogDensity2, x) = -sum(abs2, x)
dimension(::TestLogDensity2) = 20

####
#### traits
####

@test capabilities("a fish") ≡ nothing

@testset "LogDensityOrder" begin
    @test LogDensityOrder(1) == LogDensityOrder(1)
    @test_throws ArgumentError LogDensityOrder(-1)
    @test LogDensityOrder(2) ≥ LogDensityOrder(1)
end

####
#### AD backends
####

@testset "AD via ReverseDiff" begin
    ℓ = TestLogDensity()

    ∇ℓ_default = ADgradient(:ReverseDiff, ℓ)
    ∇ℓ_nocompile = ADgradient(:ReverseDiff, ℓ; compile=Val(false))
    for ∇ℓ in (∇ℓ_default, ∇ℓ_nocompile)
        @test repr(∇ℓ) == "ReverseDiff AD wrapper for " * repr(ℓ) * " (no compiled tape)"
    end

    ∇ℓ_compile = ADgradient(:ReverseDiff, ℓ; compile=Val(true))
    ∇ℓ_compile_x = ADgradient(:ReverseDiff, ℓ; compile=Val(true), x=rand(3))
    for ∇ℓ in (∇ℓ_compile, ∇ℓ_compile_x)
        @test repr(∇ℓ) == "ReverseDiff AD wrapper for " * repr(ℓ) * " (compiled tape)"
    end

    for ∇ℓ in (∇ℓ_default, ∇ℓ_nocompile, ∇ℓ_compile, ∇ℓ_compile_x)
        @test dimension(∇ℓ) == 3
        @test capabilities(∇ℓ) ≡ LogDensityOrder(1)

        for _ in 1:100
            x = rand(3)
            @test @inferred(logdensity(∇ℓ, x)) ≅ test_logdensity(x)
            @test @inferred(logdensity_and_gradient(∇ℓ, x)) ≅
                (test_logdensity(x), test_gradient(x))

            x = -x
            @test @inferred(logdensity(∇ℓ, x)) ≅ test_logdensity(x)
            if ∇ℓ.compiledtape === nothing
                # Recompute tape => correct results
                @test @inferred(logdensity_and_gradient(∇ℓ, x)) ≅
                    (test_logdensity(x), zero(x))
            else
                # Tape not recomputed => incorrect results, uses always the same branch
                @test @inferred(logdensity_and_gradient(∇ℓ, x)) ≅
                    (test_logdensity1(x), test_gradient(x))
            end
        end
    end
end

@testset "AD via ForwardDiff" begin
    ℓ = TestLogDensity()
    ∇ℓ = ADgradient(:ForwardDiff, ℓ)
    @test repr(∇ℓ) == "ForwardDiff AD wrapper for " * repr(ℓ) * ", w/ chunk size 3"
    @test dimension(∇ℓ) == 3
    @test capabilities(∇ℓ) ≡ LogDensityOrder(1)
    for _ in 1:100
        x = randn(3)
        @test @inferred(logdensity(∇ℓ, x)) ≅ test_logdensity(x)
        @test @inferred(logdensity_and_gradient(∇ℓ, x)) ≅
            (test_logdensity(x), test_gradient(x))
    end
end

@testset "chunk heuristics for ForwardDiff" begin
    @test LogDensityProblems.heuristic_chunks(82) == vcat(1:4:81, [82])
end

@testset "AD via Tracker" begin
    ℓ = TestLogDensity()
    ∇ℓ = ADgradient(:Tracker, ℓ)
    @test repr(∇ℓ) == "Tracker AD wrapper for " * repr(ℓ)
    @test dimension(∇ℓ) == 3
    @test capabilities(∇ℓ) ≡ LogDensityOrder(1)
    for _ in 1:100
        x = randn(3)
        @test @inferred(logdensity(∇ℓ, x)) ≅ test_logdensity(x)
        @test @inferred(logdensity_and_gradient(∇ℓ, x)) ≅ (test_logdensity(x), test_gradient(x))
   end
end

@testset "AD via Zygote" begin
    ℓ = TestLogDensity(test_logdensity1)
    ∇ℓ = ADgradient(:Zygote, ℓ)
    @test repr(∇ℓ) == "Zygote AD wrapper for " * repr(ℓ)
    @test dimension(∇ℓ) == 3
    @test capabilities(∇ℓ) ≡ LogDensityOrder(1)
    for _ in 1:100
        x = randn(3)
        @test @inferred(logdensity(∇ℓ, x)) ≅ test_logdensity1(x)
        @test logdensity_and_gradient(∇ℓ, x) ≅ (test_logdensity1(x), test_gradient(x))
    end
end

@static if VERSION >= v"1.6"
    @testset "AD via Enzyme" begin
        ℓ = TestLogDensity(test_logdensity1)

        ∇ℓ_reverse = ADgradient(:Enzyme, ℓ)
        @test ∇ℓ_reverse === ADgradient(:Enzyme, ℓ; mode=Enzyme.Reverse)
        @test repr(∇ℓ_reverse) == "Enzyme AD wrapper for " * repr(ℓ) * " with reverse mode"

        ∇ℓ_forward = ADgradient(:Enzyme, ℓ; mode=Enzyme.Forward)
        ∇ℓ_forward_shadow = ADgradient(:Enzyme, ℓ;
                                       mode=Enzyme.Forward,
                                       shadow=Enzyme.onehot(Vector{Float64}(undef, dimension(ℓ))))
        for ∇ℓ in (∇ℓ_forward, ∇ℓ_forward_shadow)
            @test repr(∇ℓ) == "Enzyme AD wrapper for " * repr(ℓ) * " with forward mode"
        end

        for ∇ℓ in (∇ℓ_reverse, ∇ℓ_forward, ∇ℓ_forward_shadow)
            @test dimension(∇ℓ) == 3
            @test capabilities(∇ℓ) ≡ LogDensityOrder(1)
            for _ in 1:100
                x = randn(3)
                @test @inferred(logdensity(∇ℓ, x)) ≅ test_logdensity1(x)
                @test logdensity_and_gradient(∇ℓ, x) ≅ (test_logdensity1(x), test_gradient(x))
            end
        end

        # Branches in `ADgradient`
        @test_throws ArgumentError ADgradient(:Enzyme, ℓ; mode=EnzymeTestMode())
        ∇ℓ = @test_logs (:info, "keyword argument `shadow` is ignored in reverse mode") ADgradient(:Enzyme, ℓ; shadow = (1,))
        @test ∇ℓ.shadow === nothing
    end
end

@testset "ADgradient missing method" begin
    msg = "Don't know how to AD with Foo, consider `import Foo` if there is such a package."
    @test_logs((:info, msg), @test_throws(MethodError, ADgradient(:Foo, TestLogDensity2())))
end

@testset "benchmark ForwardDiff chunk size" begin
    b = LogDensityProblems.benchmark_ForwardDiff_chunks(TestLogDensity2())
    @test b isa Vector{Pair{Int,Float64}}
    @test length(b) ≤ 20
end

@testset "stresstest" begin
    @info "stress testing"
    ℓ = TestLogDensity(x -> all(x .< 0) ? error("invalid") : -sum(abs2, x))
    failures = LogDensityProblems.stresstest(logdensity, ℓ; N = 500)
    @test 50 ≤ length(failures) ≤ 100
    @test all(x -> all(x .< 0), failures)
end
