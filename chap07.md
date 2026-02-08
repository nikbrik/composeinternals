# 7. Advanced Compose Runtime use cases

So far, the book was discussing Compose in the context of Android since it is the angle most people are coming from. The applications of Compose, however, expand far beyond Android or user interfaces. This chapter will go through some of those advanced usages with practical examples.

## Compose runtime vs Compose UI

Before jumping back into internals, it is important to set a distinction between [Compose UI and Compose runtime](https://jakewharton.com/a-jetpack-compose-by-any-other-name/). The **Compose UI** is the new UI toolkit for Android, with the tree of `LayoutNode`s which later draw their content on the canvas. The **Compose runtime** provides underlying machinery and many state/composition-related primitives.

With Compose compiler receiving support for the complete spectrum of Kotlin platforms, it is now possible to use the runtime for managing UI or any other tree hierarchies almost everywhere (as long as it runs Kotlin). Note the “other tree hierarchies” part: almost nothing in Compose runtime mentions UI (or Android) directly. While the runtime was surely created and optimized to support that use case, it is still generic enough to build tree structures of any kind. In fact, it is very similar in this matter to React JS, which primary use was to create UI on the web, but it has found much broader use in things like [synthesizers or 3D renderers](https://github.com/chentsulin/awesome-react-renderer). Most of the custom renderers reuse core functionality from React runtime but provide their own building blocks in place of browser DOM.

It is no secret that Compose devs were inspired by React while making the library. Even the first prototypes - [XML directly in Kotlin](https://twitter.com/AndroidDev/status/1363207926580711430) is reminiscent of the HTML-in-JS approach React has. Unsurprisingly, most of the third-party things made with React over the years can be replicated with Compose and run with Kotlin multiplatform.

![](resources/chapter-9-xml-compose.jpeg)
*Early prototype of Compose*

Even before the Android version of Compose was out of beta, JetBrains already started adopting Compose for Kotlin multiplatform: at the time of writing, they are working on a JVM version for desktop and JS version for browsers, with iOS rumoured to be the next. All of these examples are reusing different parts of Compose:

- Compose for Desktop managed to stay very close to the Android implementation, reusing the whole rendering layer of Compose UI, thanks to ported Skia wrappers. The event system was also extended for better support of mouse/keyboard.
- Compose for iOS (still in development) uses Skia as rendering layer as well. It also reuses a big chunk of existing logic that was portable to Kotlin/Native from JVM.
- Compose for Web went down a path of relying on browser DOM for displaying elements, reusing only compiler and runtime. The available components are defined on top of HTML/CSS, resulting in a very different system from Compose UI. The runtime and compiler, however, are used almost the same way, even though the underlying platform is completely different. With Kotlin WASM support around the corner, Skia based version of Compose is also gaining traction on web, potentially tying all three multiplatform versions together.

![](resources/chapter-9-compose-modules.png)
*Module structure of Compose with multiplatform*

And now… back to the code!

## (Re-) Introducing composition

`Composition` provides the context for all composable functions. It provides the “cache” backed by the `SlotTable` and the interface to create custom trees through `Applier`. `Recomposer` drives `Composition`, initiating recomposition whenever something (e.g. state) relevant to it has changed. As [documentation mentions](https://cs.android.com/androidx/platform/frameworks/support/+/56f60341d82bf284b8250cf8054b08ae2a91a787:compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/Composition.kt), the `Composition` is usually constructed for you by the framework itself, but guess what? This is a chapter about *unusual* use cases, and later we will manage it by ourselves a few times.

![](resources/chapter-9-composition.png)
*Composition structure*

To construct `Composition`, you can use the provided factory method:

```kotlin
1 fun Composition(
2     applier: Applier&lt;*&gt;,
3     parent: CompositionContext
4 ): Composition = ...
```
*Composition.kt*

- Parent `context` is usually available within any composable function through `rememberCompositionContext()`. Alternatively, `Recomposer` implements `CompositionContext` as well, and it is [obtainable](https://cs.android.com/androidx/platform/frameworks/support/+/56f60341d82bf284b8250cf8054b08ae2a91a787:compose/ui/ui/src/androidMain/kotlin/androidx/compose/ui/platform/WindowRecomposer.android.kt) on Android or can be created separately for your own needs.
- The second parameter is the `Applier`, dictating how to create and connect the tree produced by the `Composition`. The previous chapters already discussed it in detail before and we will go through a few good examples on how to implement it later in this chapter.

Fun fact! You can provide an `Applier` instance that does absolutely nothing, if you are here for other properties of composable functions. Even without nodes, `@Composable` annotation can power data stream conversions or event handlers which react to state changes as all composables do (see Cash App’s [Molecule](https://github.com/cashapp/molecule) for example). Just make an `Applier<Nothing>` and don’t use `ComposeNode` there!

Now into the ocean (of code) we go! The rest of this chapter focuses on using **Compose runtime** without **Compose UI**: The first example of such is from Compose UI library, where custom tree is used to render vector graphics (we briefly covered it in earlier chapters). After that, we will switch to Kotlin/JS and create a toy version of the browser DOM management library with Compose.

## Composition of vector graphics

Vector rendering in Compose is implemented through the `Painter` abstraction, similar to the `Drawable` in classic Android system:

```kotlin
 1 Image(
 2   painter = rememberVectorPainter { width, height -&gt;
 3     Group(
 4       scaleX = 0.75f,
 5       scaleY = 0.75f
 6     ) {
 7         val pathData = PathData { ... }
 8         Path(pathData = pathData)
 9     }
10   }
11 )
```
*VectorExample.kt*

The functions inside `rememberVectorPainter` block (`Group` and `Path` in particular) are composables are well, but a different kind. Instead of creating `LayoutNode`s as the other composables in Compose UI, they create elements specific to the vector. Combining them results in a vector tree, which is later drawn into the canvas.

![](resources/chapter-9-vector-composition.png)
<figcaption>Compose UI and <code>VectorPainter</code> composition.</figcaption>

The `Group` and `Path` exist in a different **composition** from the rest of the UI. That composition is contained within `VectorPainter` and only allows usage of elements describing a vector image, while usual UI composables are forbidden.

The check for vector composables is done during runtime at the moment of writing, so the compiler will happily skip over if you use `Image` or `Box` inside the `VectorPainter` block. This makes writing such painters potentially unsafe, but there were rumours of Compose compiler team improving compile-time safety for cases like this in the future.

Most of the rules about states, effects, and everything about **runtime** discussed in the previous chapters carry over from the UI composition to the vector one. For example, transition API can be used to animate changes of the vector image alongside the UI. Check Compose demos for more details: [VectorGraphicsDemo.kt](https://cs.android.com/androidx/platform/frameworks/support/+/56f60341d82bf284b8250cf8054b08ae2a91a787:compose/ui/ui/integration-tests/ui-demos/src/main/java/androidx/compose/ui/demos/VectorGraphicsDemo.kt) and [AnimatedVectorGraphicsDemo.kt](https://cs.android.com/androidx/platform/frameworks/support/+/56f60341d82bf284b8250cf8054b08ae2a91a787:compose/animation/animation/integration-tests/animation-demos/src/main/java/androidx/compose/animation/demos/vectorgraphics/AnimatedVectorGraphicsDemo.kt).

## Building vector image tree

The vector image is created from elements simpler than `LayoutNode` to better tailor to the requirements of vector graphics:

```kotlin
 1 sealed class VNode {
 2   abstract fun DrawScope.draw()
 3 }
 4 
 5 // the root node
 6 internal class VectorComponent : VNode() {
 7   val root = GroupComponent()
 8 
 9   override fun DrawScope.draw() {
10     // set up viewport size and cache drawing
11   }
12 }
13 
14 internal class PathComponent : VNode() {
15   var pathData: List&lt;PathNode&gt;
16   // more properties
17 
18   override fun DrawScope.draw() {
19     // draw path
20   }
21 }
22 
23 internal class GroupComponent : VNode() {
24   private val children = mutableListOf&lt;VNode&gt;()
25   // more properties
26 
27   override fun DrawScope.draw() {
28     // draw children with transform
29   }
30 }
```
*VNode.kt*

The nodes above define a tree structure similar to the one used in classic vector drawable XMLs. The tree itself is built from two main types of nodes:  
- `GroupComponent`, which combines children and applies a shared transform to them;  
- `PathComponent`, a leaf node (without children) that draws the `pathData`.

`fun DrawScope.draw()` provides a way to draw the content of the nodes and their children. The signature of this function is the same as in `Painter` interface which is integrated with the root of this tree later.

The same `VectorPainter` is used to show the XML vector drawable resources from the classic Android system. The XML parser creates a similar structure which is converted to a chain of `Composable` calls, resulting in the same implementation for seemingly different kinds of resources.

The tree nodes above are declared as internal, and the only way to create them is through corresponding `@Composable` declarations. Those functions are the ones used in the example with `rememberVectorPainter` at the start of this section.

```kotlin
 1 @Composable
 2 fun Group(
 3     scaleX: Float = DefaultScaleX,
 4     scaleY: Float = DefaultScaleY,
 5     ...
 6     content: @Composable () -&gt; Unit
 7 ) {
 8     ComposeNode&lt;GroupComponent, VectorApplier&gt;(
 9         factory = { GroupComponent() },
10         update = {
11             set(scaleX) { this.scaleX = it }
12             set(scaleY) { this.scaleY = it }
13             ...
14         },
15         content = content
16     )
17 }
18 
19 @Composable
20 fun Path(
21     pathData: List&lt;PathNode&gt;,
22     ...
23 ) {
24     ComposeNode&lt;PathComponent, VectorApplier&gt;(
25         factory = { PathComponent() },
26         update = {
27             set(pathData) { this.pathData = it }
28             ...
29         }
30     )
31 }
```
*VectorComposables.kt*

`ComposeNode` calls emit the node into composition, creating tree elements. Outside of that, `@Composable` functions don’t need interact with the tree at all. After the initial insertion (when the node element is created), Compose tracks updates for the defined parameters and incrementally updates related properties.

- `factory` parameter defines how the tree node gets created. Here, it is only calling constructors for corresponding `Path` or `Group` components.
- `update` provides a way to update properties of already created instance incrementally. Inside the lambda, Compose memoizes the data with helpers

(such as `fun <T> Updater.set(value: T)` or `fun <T> Updater.update(value: T)`) which refresh the tree node properties only when provided value changes to avoid unnecessary invalidations.

- `content` is the way to add child nodes to their parent. This composable parameter is executed after the update of the node is finished, and all the nodes that are emitted are then parented to the current node. `ComposeNode` also has an overload without the `content` parameter, which can be used for leaf nodes, e.g. for `Path`.

To connect child nodes to the parent, Compose uses `Applier`, briefly discussed above. `VNode`s are combined through the `VectorApplier`:

```kotlin
 1 class VectorApplier(root: VNode) : AbstractApplier&lt;VNode&gt;(root) {
 2   override fun insertTopDown(index: Int, instance: VNode) {
 3     current.asGroup().insertAt(index, instance)
 4   }
 5 
 6   override fun insertBottomUp(index: Int, instance: VNode) {
 7     // Ignored as the tree is built top-down.
 8   }
 9 
10   override fun remove(index: Int, count: Int) {
11     current.asGroup().remove(index, count)
12   }
13 
14   override fun move(from: Int, to: Int, count: Int) {
15     current.asGroup().move(from, to, count)
16   }
17 
18   override fun onClear() {
19     root.asGroup().let { it.remove(0, it.numChildren) }
20   }
21 
22   // VectorApplier only works with [GroupComponent], as it cannot add
23   // children to [PathComponent] by design
24   private fun VNode.asGroup(): GroupComponent {
25     return when (this) {
26       is GroupComponent -&gt; this
27       else -&gt; error(&quot;Cannot only insert VNode into Group&quot;)
28     }
29   }
30 }
```
*VectorApplier.kt*

Most of the methods in `Applier` interface frequently result in list operations (`insert`/`move`/`remove`). To avoid reimplementing them over and over again, `AbstractApplier` even provides convenience extensions for `MutableList`. In the case of `VectorApplier`, these list operations are implemented directly in a `GroupComponent`.

`Applier` provides two methods of insertion: `topDown` and `bottomUp`, with different order of assembling the tree:

- `topDown` first adds a node to the tree and then adds its children, inserting them one by one;
- `bottomUp` creates the node, adds all children, and only then inserts it into the tree.

The underlying reason is performance: some environments have the associated cost of adding children to the tree (think re-layout when adding a View in the classic Android system). For the vector use-case, there’s no such performance cost, so the nodes are inserted top-down. See the [`Applier` documentation](https://cs.android.com/androidx/platform/frameworks/support/+/androidx-main:compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/Applier.kt;l=67) for more information.

## Integrating vector composition into Compose UI

With the Applier in place, the vector composition is almost ready for use. The last part is the `Painter` integration.

```kotlin
 1 class VectorPainter internal constructor() : Painter() {
 2   ...
 3 
 4   // 1. Called in the context of UI composition
 5   @Composable
 6   internal fun RenderVector(
 7     content: @Composable (...) -&gt; Unit
 8   ) {
 9     // 2. The parent context is captured with [rememberCompositionContext] 
10     // to propagate its values, e.g. CompositionLocals.
11     val composition = composeVector(
12       rememberCompositionContext(),
13       content
14     )
15     
16     // 3. Whenever the UI &quot;forgets&quot; the VectorPainter, 
17     // the vector composition is disposed with [DisposableEffect] below.
18     DisposableEffect(composition) {
19       onDispose {
20         composition.dispose()
21       }
22     }
23   }
24 
25   private fun composeVector(
26     parent: CompositionContext,
27     composable: @Composable (...) -&gt; Unit
28   ): Composition {
29     ...
30     // See implementation below
31   }
32 }
```
*VectorPainter.kt*

The first part of integration is connecting Compose UI composition and the vector image composition:

1.  `RenderVector` accepts `content` with composable description of the vector image. The `Painter` instance is usually kept the same between recompositions (with `remember`), but `RenderVector` is called on each composition if `content` has changed.
2.  Creating composition always requires a parent context, and here it is taken from the UI composition with `rememberCompositionContext`. It ensures that both are connected to the same `Recomposer` and all internal values (e.g. `CompositionLocal`s for density) are propagated to the vector composition as well.
3.  The composition is preserved through updates but should be disposed whenever `RenderVector` leaves the scope. `DisposableEffect` manages this cleanup similarly to other kinds of subscriptions in Compose.

Finally, the last step is to populate the composition with image content to create a tree of vector nodes, which is later used to draw vector image on canvas:

```kotlin
 1 class VectorPainter : Painter() {
 2   // The root component for the vector tree
 3   private val vector = VectorComponent()
 4   // 1. Composition with vector elements.
 5   private var composition: Composition? = null
 6 
 7   @Composable
 8   internal fun RenderVector(
 9     content: @Composable (...) -&gt; Unit
10   ) {
11     ...
12     // See full implementation above
13   }
14 
15   private fun composeVector(
16     parent: CompositionContext,
17     composable: @Composable (...) -&gt; Unit
18   ): Composition {
19     // 2. Creates composition or reuses an existing one
20     val composition = 
21       if (this.composition == null || this.composition.isDisposed) {
22         Composition(
23           VectorApplier(vector.root),
24           parent
25         )
26       } else {
27         this.composition
28       }
29       this.composition = composition
30 
31     // 3. Sets the vector content to the updated composable value 
32     composition.setContent {
33       // Vector composables can be called inside this block only
34       composable(vector.viewportWidth, vector.viewportHeight)
35     }
36 
37     return composition
38   }
39 
40   // Painter interface integration, is called every time the system
41   // needs to draw the vector image on screen
42   override fun DrawScope.onDraw() {
43     with(vector) {
44         draw()
45     }
46   }
47 }
```
*VectorPainter.kt*

1.  The painter maintains its own composition, because `ComposeNode` requires the applier to match whatever is passed to the composition and UI context uses applier incompatible with vector nodes.
2.  This composition is refreshed if the painter was not initialized or its composition went out of scope.
3.  After creating the composition, it is populated through `setContent`, similar to the one used inside the `ComposeView`. Whenever `RenderVector` is called with different `content`, `setContent` is executed again to refresh vector structure. The content adds children to the `root` node that is later used for drawing contents of `Painter`.

With that, the integration is finished, and the `VectorPainter` can now draw `@Composable` contents on the screen. The composables inside the painter also have access to the state and composition locals from the UI composition to drive their own updates.

With that, you know how to create a custom tree and embed it into the already existing composition. In the next part, we will go through creating a standalone Compose system based on the same principles… in Kotlin/JS.

## Managing DOM with Compose

Multiplatform support is still a new thing for Compose with only runtime and compiler available outside of the JVM ecosystem. These two modules, however, is all we need to create a composition and run something in it, which leads to more experiments!

Compose compiler from Google dependencies supports all Kotlin platforms, but runtime is distributed for Android only. Jetbrains, however, publish [their own (mostly unchanged) version of Compose](https://github.com/JetBrains/compose-jb/releases) with multiplatform artifacts for JS as well.

The first step to make Compose magic happen is to figure out the tree it should operate on. Thankfully, browsers already have the “view” system in place based on HTML/CSS. We can manipulate these elements from JS through DOM ([Document Object Model](https://developer.mozilla.org/en-US/docs/Web/API/Document_Object_Model/Introduction)) API, which is also provided by Kotlin/JS standard library.

Before starting with JS, let’s look at HTML representation inside the browser.

```kotlin
1 &lt;div&gt;
2   &lt;ul&gt;
3     &lt;li&gt;Item 1&lt;/li&gt;
4     &lt;li&gt;Item 2&lt;/li&gt;
5     &lt;li&gt;Item 3&lt;/li&gt;
6   &lt;/ul&gt;
7 &lt;/div&gt;
```
*sample.html*

The HTML above displays an unordered (bulleted) list with three items. From the perspective of the browser, this structure looks like this:

![](resources/chapter-9-html-tree.png)
*HTML tree representation in the browser*

The DOM is a tree-like structure built from elements which are exposed in Kotlin/JS as `org.w3c.dom.Node`. The relevant elements for us are:

- HTML elements (subclasses of `org.w3c.dom.HTMLElement`) are representing the tags (e.g. `li` or `div`). They can be created with `document.createElement(<tagName>)` and browser will automatically find correct implementation for a tag,
- Text between the tags (e.g. `"Test"` in the examples above) represented as a `org.w3c.dom.Text`. Instances of this element can be created with `document.createTextElement(<value>)`

Using these DOM elements, JS sees this tree the following way:

![](resources/chapter-9-js-tree.png)
*HTML tree representation for JS*

These elements will provide the basis for the Compose-managed tree, similarly to how `VNode`s are used for vector image composition in the previous part.

```kotlin
 1 @Composable
 2 fun Tag(tag: String, content: @Composable () -&gt; Unit) {
 3   ComposeNode&lt;HTMLElement, DomApplier&gt;(
 4     factory = { document.createElement(tag) as HTMLElement },
 5     update = {},
 6     content = content
 7   )
 8 }
 9 
10 @Composable
11 fun Text(value: String) {
12   ReusableComposeNode&lt;Text, DomApplier&gt;(
13     factory = { document.createTextElement(&quot;&quot;) },
14     update = {
15       set(value) { this.data = it }
16     }
17   )
18 }
```
*HtmlTags.kt*

Tags cannot be changed in place, as the `<audio>` has a completely different browser representation from `<div>`, so if the tag name has changed, it should be recreated. Compose does not handle this automatically, so it is important to avoid passing different values for tag names into the same composable.

The simplest way to achieve recreation of the nodes is to wrap each node in a separate composable (e.g. `Div` and `Ul` for corresponding elements). By doing so, you create different compile-time groups for each of them, hinting to Compose that those elements should be replaced completely instead of just updating their properties.

`Text` elements, however, are structurally the same, and we indicate it with `ReusableComposeNode`. This way, even when Compose finds these nodes inside different groups, it will reuse the instance. To ensure correctness, the text node is created without content, and the value is set with `update` parameter.

To combine elements into a tree, Compose requires an `Applier` instance operating on DOM elements. The logic for it is very similar to the `VectorApplier` above, except the DOM node methods for adding/removing children are slightly different. Most of the code there is completely mechanical (moving elements to correct indices), so I will omit it here. If you are looking for a reference, I recommend checking [Applier used in Compose for Web](https://github.com/JetBrains/compose-jb/blob/6d97c6d0555f056d2616f417c4d130e0c2147e32/web/core/src/jsMain/kotlin/org/jetbrains/compose/web/DomApplier.kt#L63-L91).

## Standalone composition in the browser

To start combining our new composables into UI, Compose requires an active composition. In Compose UI, all the initialization is already done in the `ComposeView`, but for the browser environment it needs to be created from scratch.

The same principles can be applied for the different platforms as well, as all the components described below exist in the “common” Kotlin code.

```kotlin
 1 fun renderComposable(root: HTMLElement, content: @Composable () -&gt; Unit) {
 2   GlobalSnapshotManager.ensureStarted()
 3 
 4   val recomposerContext = DefaultMonotonicFrameClock + Dispatchers.Main
 5   val recomposer = Recomposer(recomposerContext)
 6 
 7   val composition = ControlledComposition(
 8     applier = DomApplier(root),
 9     parent = recomposer
10   )
11 
12   composition.setContent(content)
13 
14   CoroutineScope(recomposerContext).launch(start = UNDISPATCHED) {
15     recomposer.runRecomposeAndApplyChanges()
16   }
17 }
```
*renderComposable.kt*

`renderComposable` hides all the implementation details of composition start, providing a way to render composable elements into a DOM element. Most of the setup inside is connected to initializing `Recomposer` with correct clock and coroutine context:

- First, the snapshot system (responsible for state updates) is initialized. `GlobalSnapshotManager` is intentionally left out of runtime, and you can copy it from [Android source](https://cs.android.com/androidx/platform/frameworks/support/+/androidx-main:compose/ui/ui/src/androidMain/kotlin/androidx/compose/ui/platform/GlobalSnapshotManager.android.kt) if the target platform doesn’t have one provided. It is the only part that is not provided by the runtime at the moment.
- Next, the coroutine context for `Recomposer` is created with JS defaults. The default `MonotonicClock` for browsers is controlled with `requestAnimationFrame` (if you are using JetBrains implementation), and `Dispatchers.Main` references the only thread JS operates on. This context is used to run recompositions later.
- Now we are ready to create a composition. It is created the same way as in the vector example above, but now the recomposer is used as a composition parent (recomposer always has to be a parent of the top-most composition).
- Afterwards, composition content is set. All the updates to this composition should happen inside provided composable, as new invocations of `renderComposable` will recreate everything from scratch.
- The last part is to start the process of recompositions by launching a coroutine with `Recomposer.runRecomposeAndApplyChanges`. On Android, this process is usually tied to the activity/view lifecycle, with calling `recomposer.cancel()` to stop the recomposition process. Here, the composition lifecycle is tied to the lifetime of the page, so no cancellations are needed.

Primitives above can now be combined together to render content of a HTML page:

```kotlin
1 fun main() {
2   renderComposable(document.body!!) {
3     // equivalent of &lt;button&gt;Click me!&lt;/button&gt;
4     Tag(&quot;button&quot;) {
5       Text(&quot;Click me!&quot;)
6     }
7   }
8 }
```
*HtmlSample1.kt*

Creating static content, however, can be achieved by much easier means, and Compose was required in the first place to achieve interactivity. In most cases, we expect something to happen when the button is clicked, and in DOM it can be achieved with, similar to Android views, click listeners.

In Compose UI, many listeners are defined through `Modifier` extensions, but their implementation is specific to `LayoutNode`, thus, not usable for this toy web library. It is possible to copy `Modifier` behavior from Compose UI and adjust nodes used here to provide better integration with event listeners through modifiers, but it is left as an exercise to the reader.

```kotlin
 1 @Composable
 2 fun Tag(
 3   tag: String,
 4   // this callback is invoked on click events
 5   onClick: () -&gt; Unit = {},
 6   content: @Composable () -&gt; Unit
 7 ) {
 8   ComposeNode&lt;HTMLElement, DomApplier&gt;(
 9     factory = { createTagElement(tag) },
10     update = {
11       // when listener changes, the listener on the DOM node is re-set
12       set(onClick) { 
13         this.onclick = { _ -&gt; onClick() }
14       }
15     },
16     content = content
17   )
18 }
```
*HtmlTags.kt*

Each tag can now define a click listener as a lambda parameter which is propagated to a DOM node with handy `onclick` property defined for all `HTMLElement`s. With that addition, clicks can now be handled by passing `onClick` parameter to the `Tag` composable.

```kotlin
 1 fun main() {
 2   renderComposable(document.body!!) {
 3     // Counter state is updated on click
 4     var counterState by remember { mutableStateOf(0) }
 5 
 6     Tag(&quot;h1&quot;) {
 7       Text(&quot;Counter value: $counterState&quot;)
 8     }
 9 
10     Tag(&quot;button&quot;, onClick = { counterState++ }) {
11       Text(&quot;Increment!&quot;)
12     }
13   }
14 }
```
*HtmlSampleCounter.kt*

From here, there are multiple ways to expand this toy library, adding support for CSS, more events, and elements. JetBrains team is currently experimenting on a more advanced version of Compose for Web. It is built on the same principles as the toy version we explored in this chapter but is more advanced in many ways to support a variety of things you can build on the web. You can try [the tech demo](https://compose-web.ui.pages.jetbrains.team/) yourself with Kotlin/JS projects to learn more.

## Conclusion

In this chapter, we explored how core Compose concepts can be used to built systems outside of Compose UI. Custom compositions are harder to meet in the wild, but they are a great tool to have in your belt if you are already working in Kotlin/Compose environment.

The vector graphics composition is a good example of integrating custom composable trees into Compose UI. The same principles can be used to create other custom elements which can easily interact with states/animations/composition locals from UI composition.

It is also possible to create standalone compositions on all Kotlin platforms! We explored that by making a toy version of the DOM management library based on Compose runtime in a browser through the power of Kotlin/JS. In a similar fashion, Compose runtime is already used to manipulate UI trees in some projects outside of Android (see [Mosaic](https://github.com/JakeWharton/mosaic), Jake Wharton’s take on CLI).

I encourage you to experiment on your own ideas with Compose, and provide feedback to Compose team in \#compose Kotlin slack channel! Their primary goal is still defined by Compose UI, but they are very excited to learn more about other things Compose is used for.