using BundledWebResources
using Test
using Revise

module TestResourceModule

using BundledWebResources
using RelocatableFolders

const PLOTLY_RESOURCE = Resource(
    "https://cdn.jsdelivr.net/npm/plotly.js@2.26.2/dist/plotly.min.js";
    sha256 = "bf56aa89e1d4df155b43b9192f2fd85dfb0e6279e05c025e6090d8503d004608",
)

function plotly_resource()
    return @comptime Resource(
        "https://cdn.jsdelivr.net/npm/plotly.js@2.26.2/dist/plotly.min.js";
        sha256 = "bf56aa89e1d4df155b43b9192f2fd85dfb0e6279e05c025e6090d8503d004608",
    )
end

const DATA_DIR = @path joinpath(@__DIR__, "data")
const OUTPUT_CSS_RESOURCE = LocalResource(DATA_DIR, "output.css")

function output_css_resource()
    return @comptime LocalResource(DATA_DIR, "output.css")
end

end
@testset "BundledWebResources" begin
    @testset "Resources" begin
        @test TestResourceModule.PLOTLY_RESOURCE.name == "plotly.min.js"
        @test TestResourceModule.PLOTLY_RESOURCE.url ==
              "https://cdn.jsdelivr.net/npm/plotly.js@2.26.2/dist/plotly.min.js"
        @test TestResourceModule.PLOTLY_RESOURCE.hash ==
              "bf56aa89e1d4df155b43b9192f2fd85dfb0e6279e05c025e6090d8503d004608"
        @test !isempty(TestResourceModule.PLOTLY_RESOURCE.content)

        @test BundledWebResources.content(TestResourceModule.PLOTLY_RESOURCE) ==
              TestResourceModule.PLOTLY_RESOURCE.content

        @test TestResourceModule.plotly_resource().name == "plotly.min.js"
        @test TestResourceModule.plotly_resource().url ==
              "https://cdn.jsdelivr.net/npm/plotly.js@2.26.2/dist/plotly.min.js"
        @test TestResourceModule.plotly_resource().hash ==
              "bf56aa89e1d4df155b43b9192f2fd85dfb0e6279e05c025e6090d8503d004608"
        @test !isempty(TestResourceModule.plotly_resource().content)

        @test BundledWebResources.content(TestResourceModule.plotly_resource()) ==
              TestResourceModule.plotly_resource().content

        @test !isempty(readdir(BundledWebResources._SCRATCHSPACE[]))

        @test TestResourceModule.OUTPUT_CSS_RESOURCE.root == TestResourceModule.DATA_DIR
        @test TestResourceModule.OUTPUT_CSS_RESOURCE.path == "output.css"

        @test TestResourceModule.output_css_resource().root == TestResourceModule.DATA_DIR
        @test TestResourceModule.output_css_resource().path == "output.css"
    end

    @testset "ResourceRouter" begin
        resource_router = ResourceRouter(TestResourceModule)
        @test pathof(TestResourceModule.PLOTLY_RESOURCE) in keys(resource_router.map)
        @test BundledWebResources.HTTP.URIs.URI(
            pathof(TestResourceModule.OUTPUT_CSS_RESOURCE),
        ).path in keys(resource_router.map)

        HTTP = BundledWebResources.HTTP

        http_router = HTTP.Router()

        function content_type(req)
            for (k, v) in req.headers
                if k == "Content-Type"
                    return v
                end
            end
            error("no content type")
        end

        router = http_router |> resource_router

        res = router(HTTP.Request("GET", pathof(TestResourceModule.PLOTLY_RESOURCE)))
        @test res.status == 200
        @test content_type(res) == "text/javascript; charset=utf-8"
        @test String(res.body) == BundledWebResources.content(TestResourceModule.PLOTLY_RESOURCE)

        res = router(HTTP.Request("GET", pathof(TestResourceModule.OUTPUT_CSS_RESOURCE)))
        @test res.status == 200
        @test content_type(res) == "text/css; charset=utf-8"
        @test String(res.body) ==
              BundledWebResources.content(TestResourceModule.OUTPUT_CSS_RESOURCE)

        res = router(HTTP.Request("GET", "/"))
        @test res.status == 404
    end

    @testset "`bun` artifact" begin
        if Sys.isapple() || Sys.islinux()
            bun = BundledWebResources.bun()
            @test VersionNumber(readchomp(`$bun --version`)) > v"1"
            mktempdir() do dir
                cd(dir) do
                    run(`$bun init -y`)
                    run(`$bun add react-dom`)
                    open("Component.tsx", "w") do io
                        write(
                            io,
                            """
                            export function Component(props: {message: string}) {
                                return <p class="p-2">{props.message}</p>
                            }
                            """,
                        )
                    end
                    open("index.tsx", "w") do io
                        write(
                            io,
                            """
                            import * as ReactDOM from 'react-dom/client';
                            import {Component} from "./Component"

                            const root = ReactDOM.createRoot(document.getElementById('root'));
                            root.render(<Component message="Sup!" />)
                            """,
                        )
                    end
                    run(`$bun build ./index.tsx --outdir ./out`)

                    @test isdir("out")
                    @test isfile(joinpath("out", "index.js"))
                    @test contains(read(joinpath("out", "index.js"), String), "Sup!")
                    @test contains(read(joinpath("out", "index.js"), String), "react-dom")
                    @test contains(read(joinpath("out", "index.js"), String), "p-2")

                    @test !contains(read(joinpath("out", "index.js"), String), "Sup!!!!!")
                    @test !contains(read(joinpath("out", "index.js"), String), "text-blue-200")

                    has_rebuilt = Ref(0)
                    function after_rebuild()
                        has_rebuilt[] += 1
                    end
                    watcher = BundledWebResources.watch(;
                        after_rebuild,
                        entrypoint = "index.tsx",
                        outdir = "out",
                    )

                    @test has_rebuilt[] == 0

                    open("index.tsx", "w") do io
                        write(
                            io,
                            """
                            import * as ReactDOM from 'react-dom/client';
                            import {Component} from "./Component"

                            const root = ReactDOM.createRoot(document.getElementById('root'));
                            root.render(<Component message="Sup!!!!!" />)
                            """,
                        )
                    end

                    sleep(1)

                    @test has_rebuilt[] == 1

                    @test contains(read(joinpath("out", "index.js"), String), "Sup!!!!!")
                    @test !contains(read(joinpath("out", "index.js"), String), "text-blue-200")

                    open("Component.tsx", "w") do io
                        write(
                            io,
                            """
                            export function Component(props: {message: string}) {
                                return <p class="p-2 text-blue-200">{props.message}</p>
                            }
                            """,
                        )
                    end

                    sleep(1)

                    @test has_rebuilt[] == 2
                    @test contains(read(joinpath("out", "index.js"), String), "text-blue-200")

                    # Closing the watcher should prevent further rebuilds.
                    close(watcher)

                    open("Component.tsx", "w") do io
                        write(
                            io,
                            """
                            export function Component(props: {message: string}) {
                                return <p class="p-2">{props.message}</p>
                            }
                            """,
                        )
                    end

                    sleep(1)

                    # We haven't rebuilt since we closed the watcher and the
                    # built file is still contain the stale class.
                    @test has_rebuilt[] == 2
                    @test contains(read(joinpath("out", "index.js"), String), "text-blue-200")
                end
            end
        else
            @test_throws ErrorException BundledWebResources.bun()
        end
    end
end
