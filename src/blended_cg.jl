
function bcg(
    f,
    grad,
    lmo,
    x0;
    line_search::LineSearchMethod=adaptive,
    L=Inf,
    epsilon=1e-7,
    max_iteration=10000,
    print_iter=1000,
    trajectory=false,
    verbose=false,
    linesearch_tol=1e-7,
    emphasis::Emphasis=blas,
    Ktolerance=1.05,
    lmo_kwargs...,
)
    function print_header(data)
        @printf(
            "\n───────────────────────────────────────────────────────────────────────────────────────────────\n"
        )
        @printf(
            "%6s %13s %14s %14s %14s %14s %14s\n",
            data[1],
            data[2],
            data[3],
            data[4],
            data[5],
            data[6],
            data[7],
        )
        @printf(
            "───────────────────────────────────────────────────────────────────────────────────────────────\n"
        )
    end

    function print_footer()
        @printf(
            "───────────────────────────────────────────────────────────────────────────────────────────────\n\n"
        )
    end

    function print_iter_func(data)
        @printf(
            "%6s %13s %14e %14e %14e %14e %14i\n",
            st[Symbol(data[1])],
            data[2],
            Float64(data[3]),
            Float64(data[4]),
            Float64(data[5]),
            data[6],
            data[7],
        )
    end

    t = 0
    primal = Inf
    dual_gap = Inf
    active_set = ActiveSet([(1.0, x0)])
    x = x0
    # initial gap estimate computation
    gradient = grad(x)
    vmax = compute_extreme_point(lmo, gradient)
    phi = dot(gradient, x0 - vmax) / 2
    traj_data = []
    tt = regular
    time_start = time_ns()
    v = x0

    if line_search === shortstep && !isfinite(L)
        @error("Lipschitz constant not set to a finite value. Prepare to blow up spectacularly.")
    end

    if line_search === agnostic || line_search === nonconvex
        @error("Lazification is not known to converge with open-loop step size strategies.")
    end
    
    if verbose
        println("\nBlended Conditional Gradients Algorithm.")
        numType = eltype(x0)
        println(
            "EMPHASIS: $emphasis STEPSIZE: $line_search EPSILON: $epsilon max_iteration: $max_iteration TYPE: $numType",
        )
        println("K: $Ktolerance")
        if emphasis === memory
            println("WARNING: In memory emphasis mode iterates are written back into x0!")
        end
        headers = ("Type", "Iteration", "Primal", "Dual", "Dual Gap", "Time", "#ActiveSet")
        print_header(headers)
    end

    if emphasis === memory && !isa(x, Array)
        x = convert(Vector{promote_type(eltype(x), Float64)}, x)
    end

    while t <= max_iteration && phi ≥ epsilon
        x = if emphasis == memory
            compute_active_set_iterate!(x, active_set)
        else
            compute_active_set_iterate(active_set)
        end
        # TODO replace with single call interface from function_gradient.jl
        primal = f(x)
        gradient = grad(x)
        (idx_fw, idx_as, good_progress) = find_minmax_directions(active_set, gradient, phi)
        if good_progress
            tt = simplex_descent
            update_simplex_gradient_descent!(active_set, gradient, f, L=L)
        else
            # compute new atom
            v = lp_separation_oracle(
                lmo,
                active_set,
                gradient,
                phi,
                Ktolerance;
                inplace_loop=(emphasis == memory),
                lmo_kwargs...,
            )
            # no new vertex found -> reduce min gap progression
            if v === nothing
                tt = gap_step
                phi /= 2
            else
                tt = regular
                if line_search === agnostic
                    gamma = 2 / (2 + t)
                elseif line_search === goldenratio
                    _, gamma = segmentSearch(f, grad, x, ynew, linesearch_tol=linesearch_tol)
                elseif line_search === backtracking
                    _, gamma = backtrackingLS(f, gradient, x, v, linesearch_tol=linesearch_tol)
                elseif line_search === nonconvex
                    gamma = 1 / sqrt(t + 1)
                elseif line_search === shortstep
                    gamma = dual_gap / (L * dot(x - v, x - v))
                elseif line_search === adaptive
                    L, gamma = adaptive_step_size(f, gradient, x, x - v, L)
            end
                active_set.weights .*= (1 - gamma)
                # we push directly since ynew is by nature not in active set
                push!(active_set, (gamma, v))
                active_set_cleanup!(active_set)
            end
        end
        if v !== nothing
            dual_gap = dot(gradient, x - v)
        end
        if trajectory
            push!(
                traj_data,
                (
                    t,
                    primal,
                    primal - dual_gap,
                    dual_gap,
                    (time_ns() - time_start) / 1.0e9,
                    length(active_set),
                ),
            )
        end
        t = t + 1
        if verbose && mod(t, print_iter) == 0
            rep = (
                tt,
                string(t),
                primal,
                primal - dual_gap,
                dual_gap,
                (time_ns() - time_start) / 1.0e9,
                length(active_set),
            )
            print_iter_func(rep)
            flush(stdout)
        end
    end
    if verbose
        x = compute_active_set_iterate(active_set)
        gradient = grad(x)
        v = compute_extreme_point(lmo, gradient)
        primal = f(x)
        dual_gap = dot(x, gradient) - dot(v, gradient)
        rep = (
            last,
            string(t - 1),
            primal,
            primal - dual_gap,
            dual_gap,
            (time_ns() - time_start) / 1.0e9,
            length(active_set),
        )
        print_iter_func(rep)
        flush(stdout)
    end
    active_set_renormalize!(active_set)
    active_set_cleanup!(active_set)
    x = compute_active_set_iterate(active_set)
    gradient = grad(x)
    v = compute_extreme_point(lmo, gradient)
    primal = f(x)
    dual_gap = dot(x, gradient) - dot(v, gradient)
    if verbose
        rep = (
            pp,
            string(t - 1),
            primal,
            primal - dual_gap,
            dual_gap,
            (time_ns() - time_start) / 1.0e9,
            length(active_set),
        )
        print_iter_func(rep)
        print_footer()
        flush(stdout)
    end
    return x, v, primal, dual_gap, traj_data
end


"""
    update_simplex_gradient_descent!(active_set::ActiveSet, direction, f)

Performs a Simplex Gradient Descent step and modifies `active_set` inplace.

Algorithm reference and notation taken from:
Blended Conditional Gradients:The Unconditioning of Conditional Gradients
https://arxiv.org/abs/1805.07311
"""
function update_simplex_gradient_descent!(
    active_set::ActiveSet,
    direction,
    f;
    L=nothing,
    linesearch_tol=10e-10,
    step_lim=100,
)
    c = [dot(direction, a) for a in active_set.atoms]
    k = length(active_set)
    csum = sum(c)
    c .-= (csum / k)
    # name change to stay consistent with the paper, c is actually updated in-place
    d = c
    if norm(d) <= 1e-7
        @info "Resetting active set."
        # resetting active set to singleton
        a0 = active_set.atoms[1]
        empty!(active_set)
        push!(active_set, (1, a0))
        return active_set
    end
    η = eltype(d)(Inf)
    @inbounds for idx in eachindex(d)
        if d[idx] ≥ 0
            η = min(η, active_set.weights[idx] / d[idx])
        end
    end
    η = max(0, η)
    x = compute_active_set_iterate(active_set)
    @. active_set.weights -= η * d
    active_set_renormalize!(active_set)
    y = compute_active_set_iterate(active_set)
    if f(x) ≥ f(y)
        active_set_cleanup!(active_set)
        return active_set
    end
    # TODO move η between x and y till opt
    linesearch_method = L === nothing || !isfinite(L) ? backtracking : shortstep
    if linesearch_method == backtracking
        _, gamma =
            backtrackingLS(f, direction, x, y, linesearch_tol=linesearch_tol, step_lim=step_lim)
    else # == shortstep, just two methods here for now
        gamma = dot(direction, x - y) / (L * norm(x - y)^2)
    end
    # step back from y to x by (1 - γ) η d
    # new point is x - γ η d
    @. active_set.weights += η * (1 - gamma) * d
    # could be required in some cases?
    active_set_cleanup!(active_set)
    return active_set
end

"""
Returns either an atom `y` from the active set satisfying
the progress criterion
`dot(y, direction) ≤ dot(x, direction) - min_gap / Ktolerance`.
with `x` the current iterate stored in the active set,
or a point `y` satisfying the progress criterion using the LMO.

`inplace_loop` controls whether the iterate type allows in-place writes.
`kwargs` are passed on to the LMO oracle.
"""
function lp_separation_oracle(
    lmo::LinearMinimizationOracle,
    active_set::ActiveSet,
    direction,
    min_gap,
    Ktolerance;
    inplace_loop=true,
    kwargs...,
)
    ybest = active_set.atoms[1]
    x = active_set.weights[1] * active_set.atoms[1]
    val_best = dot(direction, ybest)
    for idx in 2:length(active_set)
        y = active_set.atoms[idx]
        if inplace_loop
            x .+= active_set.weights[idx] * y
        else
            x += active_set.weights[idx] * y
        end
        val = dot(direction, y)
        if val < val_best
            val_best = val
            ybest = y
        end
    end
    xval = dot(direction, x)
    if val_best ≤ xval - min_gap / Ktolerance
        return ybest
    end
    # otherwise, call the LMO
    y = compute_extreme_point(lmo, direction; kwargs...)
    return if dot(direction, y) ≤ xval - min_gap / Ktolerance
        y
    else
        nothing
    end
end
