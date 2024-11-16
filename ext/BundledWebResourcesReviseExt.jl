module BundledWebResourcesReviseExt

import BundledWebResources
import Revise

function BundledWebResources._updated_mtimes(current::Dict, mod::Module, ::Nothing)
    root, files = Revise.modulefiles(mod)
    root = something(root, [])
    files = something(files, [])
    non_julia_files = _local_resources(mod)
    mtimes = Dict(file => mtime(file) for file in Set(vcat(root, files, non_julia_files)))
    for (file, mtime) in mtimes
        if !haskey(current, file) || current[file] != mtime || iszero(mtime)
            @debug "file change detected" file new_mtime = mtime current_mtime = current[file]
            return true, mtimes
        end
    end
    return false, mtimes
end

function _local_resources(mod::Module)
    files = String[]
    wrapper_name = BundledWebResources.wrapper_type_name()
    if isdefined(mod, wrapper_name)
        wrapper = getfield(mod, wrapper_name)
        for name in names(mod; all = true)
            if isdefined(mod, name) && !Base.isdeprecated(mod, name)
                if BundledWebResources.is_resource(wrapper{name}())
                    object = getfield(mod, name)
                    if isa(object, Function)
                        resource = object()
                        if isa(resource, BundledWebResources.LocalResource)
                            file = joinpath(resource.root, resource.path)
                            push!(files, file)
                        end
                    end
                end
            end
        end
    end
    return files
end

end
