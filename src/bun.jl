function bun(; kws...)
    path = joinpath(Artifacts.artifact"bun", "bun$(Sys.iswindows() ? ".exe" : "")")
    return Cmd(Cmd([path]); env = copy(ENV), kws...) # Somewhat replicating JLLWrapper behavior.
end

function default_on_change()
    @debug "bun build finished"
end

# Wrapper for better printing and user interaction with the watcher object.
struct Watcher
    f::Function
end

function Base.show(io::IO, w::Watcher)
    running = istaskstarted(w.f.shutdown.task) && !istaskdone(w.f.shutdown.task)
    print(io, "$(Watcher)(running = $running)")
end

Base.close(w::Watcher) = w.f()

"""
    watch(;
        root::AbstractString = pwd(),
        entrypoint::AbstractString = "input.ts",
        outdir::AbstractString = "dist",
        after_rebuild::Function,
    ) -> Watcher

Runs `bun build --watch` in the given `root` directory, watching the
`entrypoint` file and writing to the `outdir` directory. `after_rebuild` is
called whenever the build finishes.  This is a zero-argument function that can
be used to run any code after the rebuild finishes, such as browser
auto-reloaders.

The returned `Watcher` object can be `close`d to stop the watcher.
"""
function watch(;
    root::AbstractString = pwd(),
    entrypoint::AbstractString = "index.ts",
    outdir::AbstractString = "dist",
    after_rebuild::Function = default_on_change,
)
    if isdir(root)
        cd(root) do
            if isfile(entrypoint)
                if !isdir(outdir)
                    @info "'$(outdir)' directory does not exist. Creating..."
                    mkpath(outdir)
                end

                bin = bun(; dir = pwd())

                inp = Base.PipeEndpoint()
                out = Base.PipeEndpoint()
                err = Base.PipeEndpoint()

                process = run(
                    `$(bin) build $(entrypoint) --outdir $(outdir) --watch`,
                    inp,
                    out,
                    err;
                    wait = false,
                )

                closed = Ref(false)
                task = @async begin
                    @info "running `bun build` watcher"
                    while !closed[] && process_running(process)
                        msg = strip(String(readavailable(out)))
                        if !isempty(msg)
                            rebuilt = false
                            for each in readdir(outdir)
                                if contains(msg, each)
                                    rebuilt = true
                                    break
                                end
                            end
                            if rebuilt
                                after_rebuild()
                            else
                                printstyled("\n$msg\n"; color = :red)
                            end
                        end
                    end
                    @info "`bun build` watcher exited"
                end

                function shutdown()
                    closed[] = true
                    @info "closing `bun build` watcher"
                    kill(process)
                    process_running(process) || Base.close(process)
                    Base.close(inp)
                    Base.close(out)
                    Base.close(err)
                    return wait(task)
                end

                # Ensure graceful shutdown on exit to avoid orphaned `bun`s.
                atexit() do
                    if !closed[]
                        shutdown()
                    end
                end

                return Watcher() do
                    if closed[]
                        error("`bun build` watcher already closed.")
                    else
                        shutdown()
                    end
                end
            else
                error("'$entrypoint' is not a file.")
            end
        end
    else
        error("'$root' is not a directory.")
    end
end
