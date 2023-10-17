using BundledWebResources
using Test

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
end
