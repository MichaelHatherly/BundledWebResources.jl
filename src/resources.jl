abstract type AbstractResource end

"""
    LocalResource(
        root::AbstractString,
        path::AbstractString,
        [transform::Function];
        [prefix::String = ""],
        [headers::Vector],
    )

Define a local resource to be served at the given `path`. Optionally specify a
`transform` function that takes outputs the contents of `path` as a `String`
instead; used for resources that need pre-processing, e.g. TypeScript.

`headers` allows for setting the default HTTP response headers that are sent
with the response to clients. `Cache-Control: max-age=604800, immutable` is the
default.

`prefix` defines what route prefix the resource is to be served from. This
defaults to `static`, hence the `@ResourceEndpoint` that provides this resource
to HTTP clients must be mounted on a route `/static/**`.
"""
struct LocalResource{T<:AbstractString} <: AbstractResource
    root::T
    path::String
    prefix::String
    func::Function
    headers::Vector{Pair{String,String}}

    function LocalResource(
        root::AbstractString,
        path::AbstractString,
        func::Base.Callable = _default_local_resource_func;
        prefix::String = "static",
        headers = ["Cache-Control" => "max-age=604800, immutable"],
    )
        isdir(root) || error("'$root' is not a directory.")
        if func === _default_local_resource_func && !isfile(joinpath(root, path))
            error("'$path' is not a file.")
        end

        resource = new{typeof(root)}(root, path, prefix, func, headers)

        # Run the transform function once to ensure it works and also populate
        # cached values if the `func` happens to cache content, for
        # relocatablity.
        content(resource)

        return resource
    end
end

function Base.show(io::IO, r::LocalResource)
    transformed = r.func !== _default_local_resource_func
    print(io, "$(LocalResource)($(repr(r.root)), $(repr(r.path)); transformed=$transformed)")
end

function _default_local_resource_func(root::AbstractString, path::AbstractString)
    return read(joinpath(root, path), String)
end

content(r::LocalResource) = r.func(r.root, r.path)

headers(r::LocalResource) = _set_headers(r.headers, r.path, content(r))

function Base.pathof(r::LocalResource)
    path = join(splitpath(r.path), '/')
    prefix = isempty(r.prefix) ? "" : "/$(r.prefix)"
    bytes = Vector{UInt8}(content(r))
    hash = string(Base.hash(bytes); base = 62)
    return "$prefix/$path?v=$hash"
end

"""
    bun_build([source])

On-the-fly building of local scripts using `bun` as the build tool.

If the source file and the build artifact are different file types, e.g.
TypeScript, not JavaScript, then specify `source` as the `.ts` file.
"""
function bun_build(source::Union{AbstractString,Nothing} = nothing)
    cache = Ref("")
    function bun_builder(root::AbstractString, path::AbstractString)
        if isdir(root)
            path = something(source, path)
            if isfile(joinpath(root, path))
                cache[] = readchomp(`$(bun(; dir = root)) build $(path)`)
            else
                @warn "no file found at $(joinpath(root, path)) for `bun_build`."
            end
        else
            if isempty(cache[])
                @warn "no directory found at $(root) for `bun_build` and cache is empty."
            end
        end
        return cache[]
    end
end

"""
    Resource(url::String; name::String, sha256::String, headers::Vector, prefix::String)

A remote resource that is downloaded and cached locally.

`headers` allows for setting the default HTTP response headers that are sent
with the response to clients. `Cache-Control: max-age=604800, immutable` is the
default.

`prefix` defines what route prefix the resource is to be served from. This
defaults to `static`, hence the `@ResourceEndpoint` that provides this resource
to HTTP clients must be mounted on a route `/static/**`.
"""
struct Resource <: AbstractResource
    name::String
    prefix::String
    url::String
    content::String
    hash::String
    headers::Vector{Pair{String,String}}

    function Resource(
        url::String;
        prefix::String = "static",
        name::String = basename(url),
        sha256::String = "",
        headers = ["Cache-Control" => "max-age=604800, immutable"],
    )
        computed_sha256 = _download_and_cache(url, sha256)
        if sha256 == computed_sha256
            content = read(joinpath(_SCRATCHSPACE[], sha256), String)
            headers = _set_headers(headers, name, content)
            return new(name, prefix, url, content, sha256, headers)
        else
            error(
                "SHA256 mismatch for $(repr(url)): expected $(repr(sha256)), got $(repr(computed_sha256)).",
            )
        end
    end
end

# Add the `Content-Type` header based on the filename and content of the file.
function _set_headers(headers::Vector, name::String, content::String)
    headers = copy(headers)
    has_content_type = false
    for (k, _) in headers
        if k == "Content-Type"
            # Use whatever the user has set.
            has_content_type = true
        end
    end
    if !has_content_type
        ct = _content_type_from_path(name)
        ct = isnothing(ct) ? HTTP.sniff(content) : ct
        push!(headers, "Content-Type" => ct)
    end

    push!(headers, "Content-Length" => "$(sizeof(content))")

    return headers
end

_content_type_from_path(path::AbstractString) = _content_type_from_path(MIMEs.mime_from_path(path))
_content_type_from_path(mime::MIME) = MIMEs.contenttype_from_mime(mime)
_content_type_from_path(::Nothing) = nothing

content(r::Resource) = r.content

headers(r::Resource) = r.headers

Base.show(io::IO, r::Resource) = print(io, "Resource($(repr(r.url)), $(repr(r.hash)))")

function Base.pathof(r::Resource)
    path = join((r.prefix, string(hash(r.hash); base = 62), r.name), "/")
    return "/$path"
end

struct ResourceEndpoint
    mod::Module
    map::Dict{String,HTTP.Response}
    mtimes::Dict{String,Float64}

    function ResourceEndpoint(mod::Module)
        _, mtimes = _updated_mtimes(Dict{String,Float64}(), mod, nothing)
        map = _map_responses(_resource_map(mod))
        return new(mod, map, mtimes)
    end
end

_updated_mtimes(current::Dict, ::Module, ::Any) = false, current

_map_responses(map) = Dict(p => HTTP.Response(200, headers, body) for (p, (headers, body)) in map)

Base.show(io::IO, re::ResourceEndpoint) = print(io, "$(ResourceEndpoint)($(re.mod))")

"""
    @ResourceEndpoint(mod, req)

Return an `HTTP.Response` containing the requested resource from the module `mod`.
This macro should be used within an `HTTP` handler function such as:

```julia
module Resources
# ...
end

HTTP.register!(rotuer, "GET", "/static/**", (req) -> @ResourceEndpoint(Resources, req))
```

`/static/**` should be used since all resources are, by default, served from a
`static` prefix. If you manually set the `prefix` for your defined resources
then change the registered route to match that new prefix.
"""
macro ResourceEndpoint(mod, req)
    re = ResourceEndpoint(getfield(__module__, mod)::Module)
    return :($(_get_response)($(re), $(esc(req))))
end

function _get_response(re::ResourceEndpoint, req::HTTP.Request)
    if req.method == "GET"
        uri = HTTP.URIs.URI(req.target)
        changed, new_mtimes = _updated_mtimes(re.mtimes, re.mod, nothing)
        if changed
            empty!(re.mtimes)
            merge!(re.mtimes, new_mtimes)
            @debug "file changes detected, reloading resource map."
            empty!(re.map)
            merge!(re.map, _map_responses(_resource_map(re.mod)))
            @debug "reloaded resource map." map = keys(re.map)
        end
        return get(() -> HTTP.Response(404), re.map, uri.path)
    else
        return HTTP.Response(404)
    end
end

function _resource_map(mod::Module)
    map = Dict{String,Tuple{Vector{Pair{String,String}},String}}()
    wrapper_name = wrapper_type_name()
    if isdefined(mod, wrapper_name)
        wrapper = getfield(mod, wrapper_name)
        for name in names(mod; all = true)
            if isdefined(mod, name) && !Base.isdeprecated(mod, name)
                if is_resource(wrapper{name}())
                    object = getfield(mod, name)
                    if isa(object, Function)
                        resource = object()
                        path = pathof(resource)
                        uri = HTTP.URIs.URI(path)
                        map[uri.path] = (headers(resource), content(resource))
                    end
                end
            end
        end
    end
    return map
end

wrapper_type_name() = Symbol("##$(@__MODULE__).wrapper_type_name##")
is_resource(f) = false

"""
    @register name() = Resource(...)

Mark a function as a provider of a `Resource`, or `LocalResource`. This is used
by `@ResourceEndpoint` to return the correct resource for requests.
"""
macro register(resource)
    if MacroTools.@capture(resource, (name_() = body__) | function name_()
        body__
    end)
        ename = esc(name)
        tname = wrapper_type_name()
        etname = esc(tname)
        return quote
            isdefined($(__module__), $(esc(QuoteNode(tname)))) || struct $(etname){T} end

            # Lift the resource defintion to top-level. Avoids recreating on
            # each request. `body` might contain a `return`, hence we must run
            # the `body` expression in a function def rather than just splicing
            # it into the toplevel.
            let resource = (() -> ($(esc.(body)...)))()
                global function $(ename)()
                    return resource
                end
            end

            Core.@__doc__ $(ename)

            $(@__MODULE__).is_resource(::$(etname){$(esc(QuoteNode(name)))}) = true

            $(ename)
        end
    else
        error("invalid `@register` macro call, must be a function definition with 0 arguments.")
    end
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
                @debug "Garbage collecting cached downloads. You can adjust the frequency of this operation by setting the 'gc_interval' ($(gc_interval_int)) and 'gc_interval_unit' ($(gc_interval_unit)) preferences."
                files = readdir(_SCRATCHSPACE[]; join = true)
                if length(files) > 1
                    for file in readdir(_SCRATCHSPACE[]; join = true)
                        rm(joinpath(_SCRATCHSPACE[], file))
                    end
                    @debug "Garbage collection complete. $(length(files) - 1) files removed."
                    write(last_gc_file, string(Dates.now()))
                else
                    @debug "No files to garbage collect."
                end
            end
        end
    else
        write(last_gc_file, string(Dates.now()))
    end
end

const _SCRATCHSPACE = Ref{String}(Scratch.@get_scratch!("download_cache"))
