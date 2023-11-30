# BundledWebResources.jl

_Automatic local bundling of remote resources as relocatable Julia objects_

A small Julia package to automate the process of bundling web resources from
remote URLs (usually CDNs) into embedded relocatable content that can then be
served from a single server rather than from multiple third-party sources.

## `Resource`s

```julia
using BundledWebResources

const RESOURCE = Resource(
    "https://cdn.jsdelivr.net/npm/plotly.js@2.26.2/dist/plotly.min.js";
    sha256 = "bf56aa89e1d4df155b43b9192f2fd85dfb0e6279e05c025e6090d8503d004608",
)
```

You must provide a SHA256 hash of the expected content to ensure resource
integrity of the included files. Verify the validity of the hash before
including it in any deployments.

If you want to be able to `Revise` that value without running into redefinition errors
then use the `@comptime` macro can help out with that.

```julia
using BundledWebResources

function resource()
    return @comptime Resource(
        "https://cdn.jsdelivr.net/npm/plotly.js@2.26.2/dist/plotly.min.js";
        sha256 = "bf56aa89e1d4df155b43b9192f2fd85dfb0e6279e05c025e6090d8503d004608",
    )
end
```

This will evaluate the `Resource` at compile-time such that the content of the
remote resource will be embedded in system images to avoid returning deployed
code to download the resource on initial startup.

## `LocalResource`s

Local resources, such as artifacts generated by external tools such as JS or
CSS bundlers, can be made to participate in the same system but using the
`LocalResource` type. In combination with `RelocatableFolders` this allows for
easy deployment of built artifacts via system images.

```julia
using RelocatableFolders, BundledWebResources

const DIST_DIR = @path joinpath(@__DIR__, "dist")

function resource()
    return @comptime LocalResource(DIST_DIR, "output.css")
end
```

Again using the `@comptime` macro to allow for redefinition if required. Though
using a bare `const` would usually be sufficient.

```julia
using RelocatableFolders, BundledWebResources

const DIST_DIR = @path joinpath(@__DIR__, "dist")

const CSS_OUTPUT = LocalResource(DIST_DIR, "output.css")
```

## Resource Router

The main use case of these resources is serving them to clients via an HTTP
server. A `ResourceRouter(mod::Module)` function is exported for this use. You
can define a router for all resources defined in a `Module` that can be used in
an `HTTP.jl` server. When `Revise` is loaded these resources will "live
updated", otherwise they'll remain as static content in production builds that
don't include `Revise`.

```julia
module MyBundledResources

using BundledWebResources

# ...

end

using HTTP, BundledWebResources

resource_router = ResourceRouter(MyBundledResources)
HTTP.serve(endpoint_router |> resource_router, HTTP.Sockets.localhost, 8080)
```

## Experimental web resource bundling

*This feature is subject to change.*

Experimental support for bundling web resources is provided via the `bun`
command-line tool which is provided via the Julia artifacts system and does not
need to be installed manually. **Note that `bun` does not currently support
Windows.** The `BundledWebResources.bun` function will throw an error on that
platform currently.

A `watch` function is provided that can register a callback function to be run
each time the `bun build` rebuilds the bundled files. This can be used to
trigger browser reloads or other actions.
