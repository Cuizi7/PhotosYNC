# Menu bar status icons

The selected design is [Selected-Design.png](Selected-Design.png): the app's folded S,
with an enlarged lower-right tab following the ribbon's oblique cut. The image is the
approved visual reference, not a screenshot of production rendering.

`Sources/PhotoSyncApp/RibbonStatusIcon.swift` is the native vector implementation.
Its 18 × 20 pt template images uniformly scale vector contours traced from the
approved reference, including its broad state symbols. Transparent seams, tab
gutter and symbol cutouts let AppKit tint the same artwork for light, dark and selected menus.
The status tab occupies about two thirds of the width. The six marks are plus,
sync arrows, check, pause, hourglass and exclamation. Waiting is labelled “等待中”;
errors are labelled “同步异常”. More specific waiting explanations remain available.

An enabled source's current unmounted-root diagnosis uses a translucent full S with
no tab. Ordinary waiting and other directory failures keep the status tab. Existing
error and pause priority is preserved; a mount issue cannot hide those states.
This is a presentation-only projection of existing snapshot diagnostics, with no
filesystem reads. The engine currently expresses mount absence in its Chinese root
summary rather than a dedicated reason code; the projection and tests deliberately
use that existing contract without changing the runtime or persistence model.

`StatusIconTests` compares all seven native silhouettes with the approved PNG at
equal visible height (without stretching width), requiring intersection-over-union
above 0.88. It also checks distinct template renderings at 1× and 2× and the retained
brand silhouette. Presentation/model tests cover unmounted roots, disabled sources,
nested/file diagnoses, normal waits, recovery and blocking-error priority. Native
offscreen previews are development evidence; they do not certify actual menu-bar
interaction, VoiceOver or older macOS hardware.
