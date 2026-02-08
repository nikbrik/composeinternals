# 6. Effects and effect handlers

Before jumping into effect handlers it is probably welcome to recap a bit about what to consider a side effect. That will give us some context about why it is key to keep side effects under control in our Composable trees.

## Introducing side effects

Side effects were covered in chapter one when learning about the properties of Composable functions. We learned that side effects make functions non-deterministic, and therefore they make it hard for developers to reason about code.

In essence, a side effect is anything that escapes the control and scope of a function. Imagine a function that is expected to add two numbers:

```kotlin
1 fun add(a: Int, b: Int) = a + b
```
*Add.kt*

This is also frequently referred to as a “pure” function, since it only uses its inputs to calculate a result. That result will never vary for the same input values, since the only thing the function does is adding them. Therefore we can say this function is **determinisitic**, and we can easily reason about it.

Now, let’s consider adding some collateral actions to it:

```kotlin
1 fun add(a: Int, b: Int) =
2   calculationsCache.get(a, b) ?: 
3   (a + b).also { calculationsCache.store(a, b, it) }
4 }
```
*AddWithSideEffect.kt*

We are introducing a calculations cache to save computation time if the result was already computed before. This cache escapes the control of the function, so nothing tells us whether the value read from it has not been modified since last execution, for example. Imagine that this cache is getting updated concurrently from a different thread, and suddenly two sequential calls to `get(a, b)` for the same inputs return two different values:

```kotlin
1 fun main() {
2   add(1, 2) // 3
3   // Another thread calls: cache.store(1, 2, res = 4)
4   add(1, 2) // 4
5 }
```
*AddWithSideEffect2.kt*

The add function returns a different value for the same inputs, hence it is not deterministic anymore. The same way, imagine that this cache was not in-memory but relied on a database. We could get exceptions thrown by `get` and `store` calls depending on something like currently missing a connection to the database. Our calls to `add` could also fail under unexpected scenarios.

As a recap we can say that side effects are unexpected actions happening on the side, out of what callers would expect from the function, and that can alter its behavior. Side effects make it hard for developers to reason about code, and also remove testability, opening the door to flakiness.

Different examples of side effects can be writing to or reading from a global variable, accessing a memory cache, a database, performing a network query, displaying something on screen, reading from a file… etc.

## Side effects in Compose

We learned how we fall into the same issues when side effects are executed within Composable functions, since that effectively makes the effect escape the control and constraints imposed by the Composable lifecycle.

Something we have also learned previously is how any Composable can suffer multiple recompositions. For that reason, running effects directly within a Composable is not a great idea. This is something we already mentioned in chapter 1 when listing the properties of Composable functions, one of them being that Composable functions are restartable.

Running effects inside a Composable is too risky since it can potentially compromise the integrity of our code and our application state. Let me bring back an example we used in chapter 1: A Composable function that loads its state from network:

```kotlin
 1 @Composable
 2 fun EventsFeed(networkService: EventsNetworkService) {
 3   val events = networkService.loadAllEvents() // side effect
 4 
 5   LazyColumn {
 6     items(events) { event -&gt;
 7       Text(text = event.name)
 8     }
 9   }
10 }
```
*SideEffect.kt*

The effect here will run on every recomposition, which is likely not what we are looking for. The runtime might require to recompose this Composable many times in a very short period of time. The result would be lots of concurrent effects without any coordination between them. What we probably wanted was to run the effect only once on first composition instead, and keep that state for the complete Composable lifecycle.

Now, let’s imagine that our use case is Android UI, so we are using `compose-ui` to build a Composable tree. Any Android applications contain side effects. Here is an example of what could be a side effect to keep an external state updated.

```kotlin
1 @Composable
2 fun MyScreen(drawerTouchHandler: TouchHandler) {
3   val drawerState = rememberDrawerState(DrawerValue.Closed)
4 
5   drawerTouchHandler.enabled = drawerState.isOpen
6 
7   // ...
8 }
```
*SideEffect2.kt*

This composable describes a screen with a drawer with touch handling support. The drawer state is initialized as `Closed`, but might change to `Open` over time. For every composition and recomposition, the composable notifies the `TouchHandler` about the current drawer state to enable touch handling support only when it’s `Open`.

Line `drawerTouchHandler.enabled = drawerState.isOpen` is a side effect. We’re assigning a callback reference on an external object as a **side effect of the composition**.

As we have described already, the problem on doing it right in the Composable function body is that we don’t have any control on when this effect runs, so it’ll run on every composition / recomposition, and will **never get disposed**, opening the door to potential leaks.

Getting back to the example of a network request, what would happen if, a composable that triggered a network request as a side effect, leaves the composition before it completes?. We might prefer cancelling the job at that point, right?

Since side effects are required to write stateful programs, Jetpack Compose offers mechanisms to run side effects on a lifecycle-aware manner, so one can span a job across recompositions, or get it automatically cancelled when the Composable leaves the composition. These mechanisms are called **effect handlers**.

## What we need

Compositions can be **offloaded to different threads**, executed in parallel, or in different order, among other runtime execution strategies. That’s a door for diverse potential optimizations the Compose team wants to keep open, and that is also why we would never want to run our effects right away during the composition without any sort of control.

Overall, we need mechanisms for making sure that:

- Effects run on the correct composable lifecycle step. Not too early, not too late. Just when the composable is ready for it.
- Suspended effects run on a conveniently configured runtime (Coroutine and convenient `CoroutineContext`).
- Effects that capture references have their chance to dispose those when leaving composition.
- Ongoing suspended effects are cancelled when leaving composition.
- Effects that depend on an input that varies over time are automatically disposed / cancelled and relaunched every time it varies.

These mechanisms are provided by Jetpack Compose and called **Effect handlers** 💫

> All the effect handlers shared on this post are available in the latest `1.0.0-beta02`. Remember Jetpack Compose froze public API surface when entering beta so they will not change anymore before the `1.0.0` release.

## Effect Handlers

Before describing them let me give you a sneak peek on the `@Composable` lifecycle, since that’ll be relevant from this point onwards.

Any composable enters the composition when materialized on screen, and finally leaves the composition when removed from the UI tree. Between both events, effects might run. Some effects can outlive the composable lifecycle, so you can span an effect across compositions.

This is all we need to know for now, let’s keep moving.

We could divide effect handlers in two categories:

- **Non suspended effects**: E.g: Run a side effect to initialize a callback when the Composable enters the composition, dispose it when it leaves.
- **Suspended effects**: E.g: Load data from network to feed some UI state.

## Non suspended effects

### DisposableEffect

It represents a side effect of the composition lifecycle.

- Used for non suspended effects that **require being disposed**.
- Fired the first time (when composable enters composition) and then every time its keys change.
- Requires `onDispose` callback at the end. It is disposed when the composable leaves the composition, and also on every recomposition when its keys have changed. In that case, the effect is disposed and relaunched.

```kotlin
 1 @Composable
 2 fun backPressHandler(onBackPressed: () -&gt; Unit, enabled: Boolean = true) {
 3   val dispatcher = LocalOnBackPressedDispatcherOwner.current.onBackPressedDispatcher
 4 
 5   val backCallback = remember {
 6     object : OnBackPressedCallback(enabled) {
 7       override fun handleOnBackPressed() {
 8         onBackPressed()
 9       }
10     }
11   }
12 
13   DisposableEffect(dispatcher) { // dispose/relaunch if dispatcher changes
14     dispatcher.addCallback(backCallback)
15     onDispose {
16       backCallback.remove() // avoid leaks!
17     }
18   }
19 }
```
*DisposableEffect.kt*

Here we have a back press handler that attaches a callback to a dispatcher obtained from a `CompositonLocal` (old Ambients). We want to attach the callback when the composable enters the composition, and also when the dispatcher varies. To achieve that, we can **pass the dispatcher as the effect handler key**. That’ll make sure the effect is disposed and relaunched in that case.

Callback is also disposed when the composable finally leaves the composition.

If you’d want to only run the effect once when entering the composition and dispose it when leaving you could **pass a constant as the key**: `DisposableEffect(true)` or `DisposableEffect(Unit)`.

Note that `DisposableEffect` always requires at least one key.

### SideEffect

Another side effect of the composition. This one is a bit special since it’s like a “fire on this composition or forget”. If the composition fails for any reason, it is **discarded**.

If you are a bit familiar with the internals of the Compose runtime, note that it’s an effect **not stored in the slot table**, meaning it does not outlive the composition, and it will not get retried in future across compositions or anything like that.

- Used for effects that **do not require disposing**.
- Runs after every single composition / recomposition.
- Useful to **publishing updates to external states**.

```kotlin
 1 @Composable
 2 fun MyScreen(drawerTouchHandler: TouchHandler) {
 3   val drawerState = rememberDrawerState(DrawerValue.Closed)
 4 
 5   SideEffect {
 6     drawerTouchHandler.enabled = drawerState.isOpen
 7   }
 8 
 9   // ...
10 }
```
*SideEffect.kt*

This is the same snippet we used in the beginning. Here we care about the current state of the drawer, which might vary at any point in time. In that sense, we need to notify it for every single composition or recomposition. Also, if the `TouchHandler` was a singleton living during the complete application execution because this was our main screen (always visible), we might not want to dispose the reference at all.

We can understand `SideEffect` as an effect handler meant to **publish updates** to some external state not managed by the compose `State` system to keep it always on sync.

### currentRecomposeScope

This is more an effect itself than an effect handler, but it’s interesting to cover.

As an Android dev you might be familiar with the `View` system `invalidate` counterpart, which essentially enforces a new measuring, layout and drawing passes on your view. It was heavily used to create frame based animations using the `Canvas`, for example. So on every drawing tick you’d invalidate the view and therefore draw again based on some elapsed time.

The `currentRecomposeScope` is an interface with a single purpose:

```kotlin
1 interface RecomposeScope {
2     /**
3      * Invalidate the corresponding scope, requesting the composer recompose this sc\
4 ope.
5      */
6     fun invalidate()
7 }
```
*RecomposeScope.kt*

So by calling `currentRecomposeScope.invalidate()` it will invalidate composition locally 👉 **enforces recomposition**.

It can be useful when using a source of truth that is **not a compose State** snapshot.

```kotlin
 1 interface Presenter {
 2   fun loadUser(after: @Composable () -&gt; Unit): User
 3 }
 4 
 5 @Composable
 6 fun MyComposable(presenter: Presenter) {
 7   val user = presenter.loadUser { currentRecomposeScope.invalidate() } // not a Stat\
 8 e!
 9 
10   Text(&quot;The loaded user: ${user.name}&quot;)
11 }
```
*MyComposable.kt*

Here we have a presenter and we manually invalidate to enforce recomposition when there’s a result, since we’re not using `State` in any way. This is obviously a very edgy situation, so you’ll likely prefer leveraging `State` and smart recomposition the big majority of the time.

So overall, ⚠️ Use sparingly! ⚠️. Use `State` for smart recomposition when it varies as possible, since that’ll make sure to get the most out of the Compose runtime.

> For frame based animations Compose provides APIs to suspend and await until the next rendering frame on the choreographer. Then execution resumes and you can update some state with the elapsed time or whatever leveraging smart recomposition one more time. I suggest reading [the official animation docs](https://developer.android.com/jetpack/compose/animation#targetbasedanimation) for a better understanding.

## Suspended effects

### rememberCoroutineScope

This call creates a `CoroutineScope` used to create jobs that can be thought as children of the composition.

- Used to run **suspended effects bound to the composition lifecycle**.
- Creates `CoroutineScope` bound to this composition lifecycle.
- The scope is **cancelled when leaving the composition**.
- Same scope is returned across compositions, so we can keep submitting more tasks to it and all ongoing ones will be cancelled when finally leaving.
- Useful to launch jobs **in response to user interactions**.
- Runs the effect on the applier dispatcher (Usually [`AndroidUiDispatcher.Main`](https://cs.android.com/androidx/platform/frameworks/support/+/androidx-main:compose/ui/ui/src/androidMain/kotlin/androidx/compose/ui/platform/AndroidUiDispatcher.android.kt)) when entering.

```kotlin
 1 @Composable
 2 fun SearchScreen() {
 3   val scope = rememberCoroutineScope()
 4   var currentJob by remember { mutableStateOf&lt;Job?&gt;(null) }
 5   var items by remember { mutableStateOf&lt;List&lt;Item&gt;&gt;(emptyList()) }
 6 
 7   Column {
 8     Row {
 9       TextField(&quot;Start typing to search&quot;,
10         onValueChange = { text -&gt;
11           currentJob?.cancel()
12           currentJob = scope.async {
13             delay(threshold)
14             items = viewModel.search(query = text)
15           }
16         }
17       )
18     }
19     Row { ItemsVerticalList(items) }
20   }
21 }
```
*rememberCoroutineScope.kt*

This is a throttling on the UI side. You might have done this in the past using `postDelayed` or a `Handler` with the `View` system. Every time a text input changes we want to cancel any previous ongoing jobs, and post a new one with a delay, so we always enforce a minimum delay between potential network requests, for example.

> The difference with `LaunchedEffect` is that `LaunchedEffect` is used for scoping jobs initiated by the composition, while rememberCoroutineScope is thought for scoping jobs **initiated by a user interaction**.

### LaunchedEffect

This is the suspending variant for loading the initial state of a Composable, as soon as it enters the composition.

- Runs the effect when entering the composition.
- Cancels the effect when leaving the composition.
- Cancels and relaunches the effect when key/s change/s.
- Useful to **span a job across recompositions**.
- Runs the effect on the applier dispatcher (Usually [`AndroidUiDispatcher.Main`](https://cs.android.com/androidx/platform/frameworks/support/+/androidx-main:compose/ui/ui/src/androidMain/kotlin/androidx/compose/ui/platform/AndroidUiDispatcher.android.kt)) when entering.

```kotlin
1 @Composable
2 fun SpeakerList(eventId: String) {
3   var speakers by remember { mutableStateOf&lt;List&lt;Speaker&gt;&gt;(emptyList()) }
4   LaunchedEffect(eventId) { // cancelled / relaunched when eventId varies
5     speakers = viewModel.loadSpeakers(eventId) // suspended effect
6   }
7 
8   ItemsVerticalList(speakers)
9 }
```
*LaunchedEffect.kt*

Not much to say. The effect runs once when entering then once again every time the key varies, since our effect depends on its value. It’ll get cancelled when leaving the composition.

Remember that it’s also cancelled every time it needs to be relaunched. `LaunchedEffect` **requires at least one key**.

### produceState

This is actually syntax sugar built on top of `LaunchedEffect`.

- Used when your `LaunchedEffect` ends up feeding a `State` (which is most of the time).
- Relies on `LaunchedEffect`.

```kotlin
1 @Composable
2 fun SearchScreen(eventId: String) {
3   val uiState = produceState(initialValue = emptyList&lt;Speaker&gt;(), eventId) {
4     viewModel.loadSpeakers(eventId) // suspended effect
5   }
6 
7   ItemsVerticalList(uiState.value)
8 }
```
*produceState.kt*

You can provide a default value for the state, and also **one or multiple keys**.

The only gotcha is that `produceState` allows to not pass any key, and in that case it will call `LaunchedEffect` with `Unit` as the key, making it **span across compositions**. Keep that in mind since the API surface does not make it explicit.

## Third party library adapters

We frequently need to consume other data types from third party libraries like `Observable`, `Flow`, or `LiveData`. Jetpack Compose provides adapters for the most frequent third party types, so depending on the library you’ll need to fetch a different dependency:

```kotlin
1 implementation &quot;androidx.compose.runtime:runtime:$compose_version&quot; // includes Flow \
2 adapter
3 implementation &quot;androidx.compose.runtime:runtime-livedata:$compose_version&quot;
4 implementation &quot;androidx.compose.runtime:runtime-rxjava2:$compose_version&quot;
```
*Dependencies.kt*

**All those adapters end up delegating on the effect handlers**. All of them attach an observer using the third party library apis, and end up mapping every emitted element to an ad hoc `MutableState` that is exposed by the adapter function as an immutable `State`.

Some examples for the different libraries below 👇

### LiveData

```kotlin
 1 class MyComposableVM : ViewModel() {
 2   private val _user = MutableLiveData(User(&quot;John&quot;))
 3   val user: LiveData&lt;User&gt; = _user
 4   //...
 5 }
 6 
 7 @Composable
 8 fun MyComposable() {
 9   val viewModel = viewModel&lt;MyComposableVM&gt;()
10 
11   val user by viewModel.user.observeAsState()
12 
13   Text(&quot;Username: ${user?.name}&quot;)
14 }
```
*LiveData.kt*

[Here](https://cs.android.com/androidx/platform/tools/dokka-devsite-plugin/+/master:testData/compose/source/androidx/compose/runtime/livedata/LiveDataAdapter.kt) is the actual implementation of `observeAsState` which relies on `DisposableEffect` handler.

### RxJava2

```kotlin
 1 class MyComposableVM : ViewModel() {
 2   val user: Observable&lt;ViewState&gt; = Observable.just(ViewState.Loading)
 3   //...
 4 }
 5 
 6 @Composable
 7 fun MyComposable() {
 8   val viewModel = viewModel&lt;MyComposableVM&gt;()
 9 
10   val uiState by viewModel.user.subscribeAsState(ViewState.Loading)
11 
12   when (uiState) {
13     ViewState.Loading -&gt; TODO(&quot;Show loading&quot;)
14     ViewState.Error -&gt; TODO(&quot;Show Snackbar&quot;)
15     is ViewState.Content -&gt; TODO(&quot;Show content&quot;)
16   }
17 }
```
*RxJava2.kt*

[Here](https://cs.android.com/androidx/platform/tools/dokka-devsite-plugin/+/master:testData/compose/source/androidx/compose/runtime/rxjava2/RxJava2Adapter.kt) is the implementation for `susbcribeAsState()`. Same story 🙂The same extension is also available for `Flowable`.

### KotlinX Coroutines Flow

```kotlin
 1 class MyComposableVM : ViewModel() {
 2   val user: Flow&lt;ViewState&gt; = flowOf(ViewState.Loading)
 3   //...
 4 }
 5 
 6 @Composable
 7 fun MyComposable() {
 8   val viewModel = viewModel&lt;MyComposableVM&gt;()
 9 
10   val uiState by viewModel.user.collectAsState(ViewState.Loading)
11 
12   when (uiState) {
13     ViewState.Loading -&gt; TODO(&quot;Show loading&quot;)
14     ViewState.Error -&gt; TODO(&quot;Show Snackbar&quot;)
15     is ViewState.Content -&gt; TODO(&quot;Show content&quot;)
16   }
17 }
```
*Flow.kt*

[Here](https://cs.android.com/androidx/platform/tools/dokka-devsite-plugin/+/master:testData/compose/source/androidx/compose/runtime/SnapshotState.kt) is the implementation for `collectAsState`. This one is a bit different since `Flow` needs to be consumed from a suspended context. That is why it relies on `produceState` instead which delegates on `LaunchedEffect`.

So, as you can see all these adapters rely on the effect handlers explained in this post, and you could easily write your own following the same pattern, if you have a library to integrate.