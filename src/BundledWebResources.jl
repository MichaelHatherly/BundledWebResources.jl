module BundledWebResources

import Base64
import Dates
import Downloads
import HTTP
import MIMEs
import PackageExtensionCompat
import Preferences
import SHA
import Scratch

export LocalResource
export Resource
export ResourceRouter
export @comptime

abstract type AbstractResource end

struct LocalResource{T<:AbstractString} <: AbstractResource
    root::T
    path::String
end

content(r::LocalResource) = read(joinpath(r.root, r.path), String)

function Base.pathof(r::LocalResource)
    path = join(splitpath(r.path), '/')
    content = read(joinpath(r.root, r.path))
    hash = string(Base.hash(content); base = 62)
    return "/$path?v=$hash"
end

"""
    @comptime ex

Evaluate an expression at compile time. This is useful for
constructing `Resource` objects at compile time, e.g.:

```julia
my_resource() = @comptime Resource("https://example.com/my_resource.txt"; sha256="...")
```

while still allowing the value to be "`Revise`-able", since it isn't a global
constant, and instead is a function return value.
"""
macro comptime(ex)
    Core.eval(__module__, ex)
end

"""
    Resource(url::String; name::String, sha256::String)

A remote resource that is downloaded and cached locally.
"""
struct Resource <: AbstractResource
    name::String
    url::String
    content::String
    hash::String

    function Resource(url::String; name::String = basename(url), sha256::String = "")
        computed_sha256 = _download_and_cache(url, sha256)
        if sha256 == computed_sha256
            content = read(joinpath(_SCRATCHSPACE[], sha256), String)
            return new(name, url, content, sha256)
        else
            error(
                "SHA256 mismatch for $(repr(url)): expected $(repr(sha256)), got $(repr(computed_sha256)).",
            )
        end
    end
end

content(r::Resource) = r.content

Base.show(io::IO, r::Resource) = print(io, "Resource($(repr(r.url)), $(repr(r.hash)))")

function Base.pathof(r::Resource)
    path = join(("resource", string(hash(r.hash); base = 62), r.name), "/")
    return "/$path"
end

"""
    ResourceRouter(mod::Module)
    
A middleware that serves resources defined in `mod` at the paths returned by
`pathof` for each resource.
"""
ResourceRouter(mod::Module) = _resource_router(mod)

function _resource_router(mod)
    map = _resource_map(mod)
    return function (handler)
        return function (req::HTTP.Request)
            return _resource_request_handler(map, handler, req)
        end
    end
end

function _resource_request_handler(map, handler, req)
    uri = HTTP.URIs.URI(req.target)
    path = uri.path
    if req.method == "GET" && haskey(map, path)
        content_type, body = map[path]
        return HTTP.Response(200, ["Content-Type" => content_type], body)
    else
        return handler(req)
    end
end

function _resource_map(mod::Module)
    map = Dict{String,Tuple{String,String}}()
    for name in names(mod; all = true)
        if isdefined(mod, name) && !Base.isdeprecated(mod, name)
            object = getfield(mod, name)
            if isa(object, Function)
                T = Core.Compiler.return_type(object, Tuple{})
                if T <: AbstractResource && T !== Union{}
                    resource = object()
                    path = pathof(resource)
                    uri = HTTP.URIs.URI(path)
                    mime = MIMEs.mime_from_path(uri.path)
                    content_type = MIMEs.contenttype_from_mime(mime)
                    map[uri.path] = (content_type, content(resource))
                end
            end
        end
    end
    return map
end

function _download_and_cache(url::String, sha256::String)
    cached_path = joinpath(_SCRATCHSPACE[], sha256)
    if isfile(cached_path)
        return sha256
    else
        buffer = IOBuffer()
        Downloads.download(url, buffer)
        seekstart(buffer)
        hash = bytes2hex(SHA.sha256(buffer))
        path = joinpath(_SCRATCHSPACE[], hash)
        seekstart(buffer)
        write(path, buffer)
        return hash
    end
end

function _gc_cached_downloads!()
    last_gc_file = joinpath(_SCRATCHSPACE[], "last_gc")
    if isfile(last_gc_file)
        last_gc_str = read(last_gc_file, String)
        if isempty(last_gc_str)
            write(last_gc_file, string(Dates.now()))
        else
            last_gc = tryparse(Dates.DateTime, last_gc_str)
            last_gc isa Dates.DateTime ||
                error("Invalid 'last_gc' file: $last_gc_str. Must be a valid DateTime.")

            gc_interval_unit = Preferences.@load_preference("gc_interval_unit", "months")

            units = Dict(
                "years" => Dates.Year,
                "months" => Dates.Month,
                "weeks" => Dates.Week,
                "days" => Dates.Day,
                "hours" => Dates.Hour,
                "minutes" => Dates.Minute,
                "seconds" => Dates.Second,
            )

            haskey(units, gc_interval_unit) || error(
                "Invalid 'gc_interval_unit': $gc_interval_unit. Must be one of $(keys(units)).",
            )

            gc_interval_int = Preferences.@load_preference("gc_interval", 1)
            gc_interval_int isa Integer ||
                error("Invalid 'gc_interval': $gc_interval_int. Must be an integer.")

            gc_interval_int < 1 &&
                error("Invalid 'gc_interval': $gc_interval_int. Must be greater than 0.")

            gc_interval_period = units[gc_interval_unit](gc_interval_int)

            if (last_gc + gc_interval_period) < Dates.now()
                @info "Garbage collecting cached downloads. You can adjust the frequency of this operation by setting the 'gc_interval' ($(gc_interval_int)) and 'gc_interval_unit' ($(gc_interval_unit)) preferences."
                files = readdir(_SCRATCHSPACE[]; join = true)
                if length(files) > 1
                    for file in readdir(_SCRATCHSPACE[]; join = true)
                        rm(joinpath(_SCRATCHSPACE[], file))
                    end
                    @info "Garbage collection complete. $(length(files) - 1) files removed."
                    write(last_gc_file, string(Dates.now()))
                else
                    @info "No files to garbage collect."
                end
            end
        end
    else
        write(last_gc_file, string(Dates.now()))
    end
end

const _SCRATCHSPACE = Ref{String}(Scratch.@get_scratch!("download_cache"))

function __init__()
    PackageExtensionCompat.@require_extensions
    _SCRATCHSPACE[] = Scratch.@get_scratch!("download_cache")
    isdir(_SCRATCHSPACE[]) || mkdir(_SCRATCHSPACE[])
    _gc_cached_downloads!()
    return nothing
end

end # module WebResourceCaching
