#if os(macOS)
import Foundation

/// Composition root for the app's domain services. Each `AppViewModel+`
/// concern becomes a service here as it is migrated; `AppViewModel` holds the
/// provider and forwards to the services so un-migrated code keeps compiling.
@MainActor
final class ServiceProvider {
    let profiles: ProfileService
    let imageService: ImageService
    let renderService: RenderService
    let previews: ProfilePreviewsService
    let exportService: ExportService
    let viewport: ViewportService

    init(profiles: ProfileService = ProfileService(),
         imageService: ImageService = ImageService()) {
        self.profiles = profiles
        self.imageService = imageService
        self.renderService = RenderService(profiles: profiles, images: imageService)
        self.previews = ProfilePreviewsService(profiles: profiles, images: imageService)
        self.exportService = ExportService(profiles: profiles, images: imageService, renderState: renderService)
        self.viewport = ViewportService(profiles: profiles, images: imageService, renderState: renderService, previews: previews)
    }
}
#endif
