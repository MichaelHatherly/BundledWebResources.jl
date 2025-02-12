module BundledWebResources

# Imports:

import Artifacts
import Dates
import Downloads
import HTTP
import MIMEs
import MacroTools
import PackageExtensionCompat
import Preferences
import SHA
import Scratch

# Exports:

export @ResourceEndpoint
export @register
export LocalResource
export Resource

# Includes:

include("bun.jl")
include("resources.jl")

# Initialisation:

function __init__()
    PackageExtensionCompat.@require_extensions
    _SCRATCHSPACE[] = Scratch.@get_scratch!("download_cache")
    isdir(_SCRATCHSPACE[]) || mkdir(_SCRATCHSPACE[])
    _gc_cached_downloads!()
    return nothing
end

end # module WebResourceCaching
