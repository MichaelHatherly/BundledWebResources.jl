import Pkg
import SHA
import URIs
import ZipFile

pkgname = "bun"
build = 0
bun_repo = "https://github.com/oven-sh/bun"

latest_stable_release = mktempdir() do dir
    if @isdefined(latest_stable_release) && isa(latest_stable_release, VersionNumber)
        return latest_stable_release
    else
        cd(dir) do
            run(`git clone $bun_repo`)
            cd("bun") do
                text = strip(readchomp(`git tag --sort=-creatordate `))
                tags = map(split(text, '\n')) do line
                    re = r"bun\-v(\d+\.\d+\.\d+)"
                    m = match(re, line)
                    return isnothing(m) ? nothing : tryparse(VersionNumber, m.captures[1])
                end
                tags = filter(!isnothing, tags)
                stable_releases =
                    sort(filter(x -> x.build == x.prerelease == (), tags); rev = true)
                return first(stable_releases)
            end
        end
    end
end

@info "Latest stable version" latest_stable_release

release_url = "$(bun_repo)/releases/download/bun-v$(latest_stable_release)"

sha256sums_url = "$(release_url)/SHASUMS256.txt"
sha256sums = Dict{String,String}()
for line in eachline(download(sha256sums_url))
    sha, file = strip.(split(line, ' '; limit = 2))
    sha256sums[file] = sha
end

triplets = [
    "bun-darwin-aarch64.zip" => Pkg.BinaryPlatforms.MacOS(:aarch64),
    "bun-darwin-x64.zip" => Pkg.BinaryPlatforms.MacOS(:x86_64),
    "bun-linux-aarch64.zip" => Pkg.BinaryPlatforms.Linux(:aarch64),
    "bun-linux-x64.zip" => Pkg.BinaryPlatforms.Linux(:x86_64),

    # TODO: bun does not yet support Windows properly.
    # "bun-windows-aarch64.zip" => Pkg.BinaryPlatforms.Windows(:aarch64),
    # "bun-windows-x64.zip" => Pkg.BinaryPlatforms.Windows(:x86_64),
]

function create_artifacts(version)
    build_path = joinpath(@__DIR__, "artifacts")
    ispath(build_path) && rm(build_path; recursive = true, force = true)

    artifact_toml = joinpath(@__DIR__, "..", "Artifacts.toml")
    if isfile(artifact_toml)
        rm(artifact_toml)
    end
    touch(artifact_toml)

    for (triple, platform) in triplets
        url = "$(release_url)/$triple"
        @info "downloading" url
        zip_file = open(download(url))

        @info "Verifying zip"
        downloaded_sha = bytes2hex(SHA.sha256(zip_file))

        sha = sha256sums[triple]

        @info "SHA256" downloaded_sha sha
        downloaded_sha == sha ||
            error("SHA256 mismatch for $url, expected $sha, got $downloaded_sha.")

        product_hash = Pkg.Artifacts.create_artifact() do artifact_dir
            for file in ZipFile.Reader(zip_file).files
                content = read(file)
                if !isempty(content)
                    path = joinpath(artifact_dir, splitpath(file.name)[2:end]...)
                    @info "writing" path
                    ispath(dirname(path)) || mkdir(dirname(path))
                    write(path, content)
                    if endswith(path, "bun") || endswith(path, "bun.exe")
                        chmod(path, 0o777)
                    end
                end
            end

            files = readdir(artifact_dir)
            @show files
        end

        archive_filename = "$pkgname-$version+$build-$(Pkg.BinaryPlatforms.triplet(platform)).tar.gz"
        download_hash =
            Pkg.Artifacts.archive_artifact(product_hash, joinpath(build_path, archive_filename))
        @info "product hash" product_hash

        @info "file summary" url product_hash sha

        Pkg.Artifacts.bind_artifact!(
            artifact_toml,
            "bun",
            product_hash,
            platform = platform,
            force = true,
            lazy = false,
            download_info = Tuple[(
                "https://github.com/MichaelHatherly/BundledWebResources.jl/releases/download/bun-$(URIs.escapeuri("$(version)+$(build)"))/$archive_filename",
                download_hash,
            )],
        )
    end

    # Write to github actions outputs
    name = "bun_version"
    value = "bun-v$(version)+$(build)"
    if haskey(ENV, "GITHUB_OUTPUT")
        @info "Writing to GitHub Actions output" name value
        open(strip(ENV["GITHUB_OUTPUT"]), "a") do io
            println(io, "$(name)=$(value)")
        end
    else
        @warn "GITHUB_OUTPUT not set, not writing to output." name value
    end
end

create_artifacts(latest_stable_release)
