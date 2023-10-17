module BundledWebResourcesReviseExt

import BundledWebResources
import HTTP
import Revise

function BundledWebResources._resource_router(mod::Module)
    _, mtimes = _updated_mtimes(Dict(), mod)
    map = BundledWebResources._resource_map(mod)
    return function (handler)
        return function (req::HTTP.Request)
            changed, new_mtimes = _updated_mtimes(mtimes, mod)
            if changed
                empty!(mtimes)
                merge!(mtimes, new_mtimes)
                @debug "file changes detected, reloading resource map"
                empty!(map)
                merge!(map, Base.invokelatest(BundledWebResources._resource_map, mod))
                @debug "reloaded resource map" map
            end
            return Base.invokelatest(
                BundledWebResources._resource_request_handler,
                map,
                handler,
                req,
            )
        end
    end
end

function _updated_mtimes(current::Dict, mod::Module)
    root, files = Revise.modulefiles(mod)
    non_julia_files = _local_resources(mod)
    mtimes = Dict(file => mtime(file) for file in Set(vcat(root, files, non_julia_files)))
    for (file, mtime) in mtimes
        if !haskey(current, file) || current[file] != mtime
            @debug "file change detected" file new_mtime = mtime current_mtime = current[file]
            return true, mtimes
        end
    end
    return false, mtimes
end

function _local_resources(mod::Module)
    files = String[]
    for name in names(mod; all = true)
        if isdefined(mod, name) && !Base.isdeprecated(mod, name)
            object = getfield(mod, name)
            if isa(object, Function)
                T = Core.Compiler.return_type(object, Tuple{})
                if T <: BundledWebResources.LocalResource && T !== Union{}
                    resource = object()
                    file = joinpath(resource.root, resource.path)
                    push!(files, file)
                end
            end
        end
    end
    return files
end

end
