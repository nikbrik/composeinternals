# 1. Composable functions

## The meaning of Composable functions

Probably the most adequate way to start a book about Jetpack Compose internals would be by learning about Composable functions, given those are the atomic building blocks of Jetpack Compose, and the construct we will use to write our composable trees. I intentionally say “trees” here, since composable functions can be understood as nodes in a larger tree that the Compose runtime will represent in memory. We will get to this in detail when the time comes, but it is good to start growing the correct mindset from the very beginning.

If we focus on plain syntax, any standard Kotlin function can become a Composable function just by annotating it as `@Composable`:

```kotlin
1 @Composable
2 fun NamePlate(name: String) {
3   // Our composable code
4 }
```

By doing this we are essentially telling the compiler that the function intends to convert some data into a node to register in the composable tree. That is, if we read a Composable function as `@Composable (Input) -> Unit`, the input would be the data, and the output would not be a value returned from the function as most people would think, but an action registered to insert the element into the tree. We could say that this happens as a side effect of executing the function.

Note how returning `Unit` from a function that takes an input means we are likely consuming that input somehow within the body of the function.

The described action is usually known as “emitting” in the Compose jargon. Composable functions emit when executed, and that happens during the composition process. We will learn every detail about this process in the upcoming chapters. For the time being, every time we read something about “composing” a Composable function, let’s simply think of it as an equivalent of “executing” it.

![](resources/composable_function.png)
*Composable function emits image*

The only purpose of executing our Composable functions is to build or update the in-memory representation of the tree. That will keep it always up to date with the structure it represents, since Composable functions will re-execute whenever the data they read changes. To keep the tree updated, they can emit actions to insert new nodes as explained above, but they can also remove, replace, or move nodes around. Composable functions can also read or write state from/to the tree.

## Properties of Composable functions

There are other relevant implications of annotating a function as Composable. The `@Composable` annotation effectively **changes the type of the function** or expression that it is applied to, and as any other type, it imposes some constraints or properties over it. These properties are very relevant to Jetpack Compose since they unlock the library capabilities.

The Compose runtime expects Composable functions to comply to the mentioned properties, so it can assume certain behaviors and therefore exploit different runtime optimizations like parallel composition, arbitrary order of composition based on priorities, smart recomposition, or positional memoization among others. But please, don’t feel overwhelmed about all these new concepts yet, we will dive into every single one in depth at the right time.

Generically speaking, runtime optimizations are only possible when a runtime can have some certainties about the code it needs to run, so it can assume specific conditions and behaviors from it. This unlocks the chance to execute, or in other words “consume” this code following different execution strategies or evaluation techniques that take advantage of the mentioned certainties.

An example of these certainties could be the relation between the different elements in code. Are they dependant on each other or not? Can we run them in parallel or different order without affecting the program result? Can we interpret each atomic piece of logic as a completely isolated unit?

Let’s learn about the properties of Composable functions.

## Calling context

Most of the properties of Composable functions are enabled by the Compose compiler. Since it is a Kotlin compiler plugin, it runs during the normal compiler phases, and has access to all the information that the Kotlin compiler has access to. This allows it to intercept and transform the IR (intermediate representation) of all the Composable functions from our sources in order to add some extra information to them.

One of the things added to each Composable function is a new parameter, at the end of the parameters list: The `Composer`. This parameter is implicit, the developer remains agnostic of it. An instance of it is injected at runtime, and forwarded to all the child Composable calls so it is accessible from all levels of the tree.

![](resources/calling_context.png)
*Composable function emits image*

In code, let’s say we have the following Composable:

```kotlin
1 @Composable
2 fun NamePlate(name: String, lastname: String) {
3   Column(modifier = Modifier.padding(16.dp)) {
4     Text(text = name)
5     Text(text = lastname, style = MaterialTheme.typography.subtitle1)
6   }
7 }
```

The Compiler will transform it into something like this:

```kotlin
 1 fun NamePlate(name: String, lastname: String, $composer: Composer&lt;*&gt;) {
 2   ...
 3   Column(modifier = Modifier.padding(16.dp), $composer) {
 4     Text( 
 5       text = name,
 6       $composer
 7     )
 8     Text(
 9       text = lastname,
10       style = MaterialTheme.typography.subtitle1,
11       $composer
12     )
13   }
14   ...
15 }
```

As we can see, the `Composer` is forwarded to all the Composable calls within the body. On top of this, the Compose compiler imposes a strict rule to Composable functions: They can only be called from other Composable functions. This is the actual **calling context** required, and it ensures that the tree is conformed of only Composable functions, so the `Composer` can be forwarded down.

The `Composer` is the connection between the Composable code we write as developers, and the Compose runtime. Composable functions will use it to emit their changes for the tree and therefore inform the runtime about its shape in order to build its in-memory representation or update it.

## Idempotent

Composable functions are expected to be idempotent relative to the node tree they produce. Re-executing a Composable function multiple times using the same input parameters should result in the same tree. The Jetpack Compose runtime relies on this assumption for things like recomposition.

In Jetpack Compose, **recomposition** is the action of re-executing Composable functions when their inputs vary, so they can emit updated information and update the tree. The runtime must have the ability to recompose our Composable functions at arbitrary times, and for diverse reasons.

The recomposition process traverses down the tree checking which nodes need to be recomposed (re-executed). Only the nodes with varying inputs will recompose, and the rest will be **skipped**. Skipping a node is only possible when the Composable function representing it is idempotent, since the runtime can assume that given the same input, it will produce the same results. Those results are already in-memory, hence Compose does not need to re-execute it.

## Free of uncontrolled side effects

A side effect is any action that escapes the control of the function where it is called in order to do something unexpected on the side. Things like reading from a local cache, making a network call, or setting a global variable are considered side effects. They make the calling function dependant on external factors that might influence its behavior: external state that might be written from other threads, third party apis that might throw, etc. In other words, the function does not depend on its inputs only to produce a result.

Side effects are **a source of ambiguity**. That is not great for Compose, since the runtime expects Composable functions to be predictable (deterministic), so they can be re-executed multiple times safely. If a Composable function ran side effects, it could produce a different program state on every execution, making it not idempotent.

Let’s imagine that we ran a network request directly from the body of a Composable function, like this:

```kotlin
 1 @Composable
 2 fun EventsFeed(networkService: EventsNetworkService) {
 3   val events = networkService.loadAllEvents()
 4 
 5   LazyColumn {
 6     items(events) { event -&gt;
 7       Text(text = event.name)
 8     }
 9   }
10 }
```

This would be very risky, since this function might get re-executed multiple times in a short period of time by the Compose runtime, making the network request trigger multiple times and spiral out of control. It is actually worse than that, since those executions might happen from different threads without any coordination.

The Compose runtime reserves the right to pick the execution strategies for our Composable functions. It can offload recompositions to different threads to take advantage of multiple cores, or run them in any arbitrary order based on its own needs or priorities (E.g: Composables not showing on screen could get assigned a lower priority).

Another common caveat of side effects is that we could make a Composable function depend on the result of another Composable function, imposing a relation of order. That should be avoided at all cost. An example of this:

```kotlin
1 @Composable
2 fun MainScreen() {
3   Header()
4   ProfileDetail()
5   EventList()
6 }
```

In this snippet, `Header`, `ProfileDetail` and `EventList` might execute in any order, or even in parallel. We should not write logics that assume any specific execution order, like reading an external variable from `ProfileDetail` that is expected to be written from `Header`.

Generically speaking, side effects are not ideal in Composable functions. We must try making all our Composable functions stateless, so they get all their inputs as parameters, and only use them to produce a result. This makes Composables simpler, dumber, and highly reusable. However, side effects are needed to write stateful programs, so at some level we will need to run them (frequently at the root of our Composable tree). Programs need to run network requests, persist information in databases, use memory caches, etc. For this reason, Jetpack Compose offers mechanisms to call effects from Composable functions safely and within a controlled environment: The **effect handlers**.

Effect handlers make side effects aware of the Composable lifecycle, so they can be constrained/driven by it. They allow effects to be automatically disposed/canceled when the Composable leaves the tree, re-triggered if the effect inputs change, or even span the same effect across executions (recompositions) so it is only called once. We will cover effect handlers in detail in later chapters. They will allows us to avoid calling effects directly from the Composable’s body without any control.

## Restartable

We have mentioned this a few times already. Composable functions can recompose, so they are not like standard functions, in the sense that they will not be called only once as part of a call stack. This is how a normal call stack would look. Each function gets called once, and it can call one or multiple other functions.

![](resources/restartable1.png)
*Composable function emits image*

On the other hand, Composable functions can be restarted (re-executed, recomposed) multiple times, so the runtime keeps a reference to them in order to do so. Here is how a Composable call tree could look:

![](resources/restartable2.png)
*Composable function emits image*

Composables 4 and 5 are re-executed after their inputs change.

Compose is selective about which nodes of the tree to restart in order to keep its in-memory representation always up to date. Composable functions are designed to be reactive and re-executed based on changes in the state they observe.

The Compose compiler finds all Composable functions that read some state and generates the code required to teach the runtime how to restart them. Composables that don’t read state don’t need to be restarted, so there is no reason to teach the runtime how to do so.

## Fast execution

We can think of Composable functions and the Composable function tree as a fast, declarative, and lightweight approach to build a description of the program that will be retained in memory and interpreted / materialized in a later stage.

Composable functions don’t build and return UI. They simply emit data to build or update an in-memory structure. That makes them blazing fast, and allows the runtime to execute them multiple times without fear. Sometimes it happens very frequently, like for every frame of an animation.

Developers must fulfill this expectation when writing code. Any cost heavy computation should be offloaded to coroutines and always wrapped into one of the lifecycle aware effect handlers that we will learn about ahead in this book.

## Positional memoization

Positional memoization is a form of function memoization. Function memoization is the ability of a function to cache its result based on its inputs, so it does not need to be computed again every time the function is called for the same inputs. As we already learned, that is only possible for pure (**deterministic**) functions, since we have the certainty that they will always return the same result for the same inputs, hence we can cache and reuse the value.

Function memoization is a technique widely known in the Functional Programming paradigm, where programs are defined as a composition of pure functions.

In function memoization, a function call can be identified through a combination of its name, type, and parameter values. A unique key can be created using those elements, and used to store/index/read the cached result in later calls. In Compose, an additional element is considered: Composable functions have constant knowledge about **their location in the sources**. The runtime will generate different ids (unique within the parent) when the same function is called with the same parameter values but from different places:

```kotlin
1 @Composable
2 fun MyComposable() {
3   Text(&quot;Hello&quot;) // id 1
4   Text(&quot;Hello&quot;) // id 2
5   Text(&quot;Hello&quot;) // id 3
6 }
```

The in-memory tree will store three different instances of it, each one with a different identity.

![](resources/positional_memoization.png)
*Composable function emits image*

Composable identity is preserved across recompositions, so the runtime can appeal to this structure to know whether a Composable was called previously, and skip it if possible.

Sometimes assigning unique identities can be hard for the Compose runtime. One example is lists of Composables generated from a loop:

```kotlin
1 @Composable
2 fun TalksScreen(talks: List&lt;Talk&gt;) {
3   Column {
4     for (talk in talks) {
5       Talk(talk)
6     }
7   }
8 }
```

In this case, `Talk(talk)` is called from the same position every time, but each talk represents a different item on the list, and therefore a different node on the tree. In cases like this, the Compose runtime relies on the **order of calls** to generate the unique id, and still be able to differentiate them. This works nicely when adding a new element to the end of the list, since the rest of the calls stay in the same position as before. But what if we added elements to the top, or somewhere in the middle? The runtime would recompose all the `Talk`s below that point since they shifted their position, even if their inputs have not changed. This is highly inefficient (esp. for long lists), since those calls should have been skipped.

To solve this, Compose provides the `key` Composable, so we can assign an explicit key to the call manually:

```kotlin
 1 @Composable
 2 fun TalksScreen(talks: List&lt;Talk&gt;) {
 3   Column {
 4     for (talk in talks) {
 5       key(talk.id) { // Unique key
 6         Talk(talk)
 7       }
 8     }
 9   }
10 }
```

In this example we are using the talk id (likely unique) as the key for each `Talk`, which will allow the runtime to preserve the identity of all the items on the list **regardless of their position**.

Positional memoization allows the runtime to remember Composable functions by design. Any Composable function inferred as restartable by the Compose compiler should also be skippable, hence **automatically remembered**. Compose is built on top of this mechanism.

Sometimes developers need to appeal to this in-memory structure in a more granular way than the scope of a Composable function. Let’s say we wanted to cache the result of a heavy calculation that takes place within a Composable function. The Compose runtime provides the `remember` function for that matter:

```kotlin
 1 @Composable
 2 fun FilteredImage(path: String) {
 3   val filters = remember { computeFilters(path) }
 4   ImageWithFiltersApplied(filters)
 5 }
 6 
 7 @Composable
 8 fun ImageWithFiltersApplied(filters: List&lt;Filter&gt;) {
 9   TODO()
10 }
```

Here, we use `remember` to cache the result of an operation to precompute the filters of an image. The key for indexing the cached value will be based on the call position in the sources, and also the function input, which in this case is the file path. The `remember` function is just a Composable function that knows how to read from and write to the in-memory structure that holds the state of the tree. It only exposes this “positional memoization” mechanism to the developer.

In Compose, memoization is not application-wide. When something is memoized, it is done within the context of the Composable calling it. In the example from above, it would be `FilteredImage`. In practice, Compose will go to the in-memory structure and look for the value in the range of slots where the information for the enclosing Composable is stored. This makes it be more like **a singleton within that scope**. If the same Composable was called from a different parent, a new instance of the value would be returned.

## Similarities with suspend functions

Kotlin `suspend` functions can only be called from other `suspend` functions, so they also require a calling context. This ensures that `suspend` functions can only be chained together, and gives the Kotlin compiler the chance to inject and forward a runtime environment across all the computation levels. This runtime is added to each `suspend` function as an extra parameter at the end of the parameters list: The `Continuation`. This paremeter is also implicit, so developers can remain agnostic of it. The `Continuation` is used to unlock some new powerful features in the language.

Sounds familiar, right?

In the Kotlin coroutine system, a `Continuation` is like a callback. It tells the program how to continue the execution.

Here is an example. A code like the following:

```kotlin
1 suspend fun publishTweet(tweet: Tweet): Post = ...
```

Is replaced by the Kotlin compiler with:

```kotlin
1 fun publishTweet(tweet: Tweet, callback: Continuation&lt;Post&gt;): Unit
```

The `Continuation` carries all the information that the Kotlin runtime needs to suspend and resume execution from the different suspension points in our program. This makes `suspend` another good example of how requiring a calling context can serve as a means for carrying implicit information across the execution tree. Information that can be used at runtime to enable advanced language features.

In the same way, we could also understand `@Composable` as a language feature. It makes standard Kotlin functions restartable, reactive, etc.

A fair question to make at this point is why the Jetpack Compose team didn’t use `suspend` for achieving their wanted behavior. Well, even if both features are really similar in the pattern they implement, both are enabling completely different features in the language.

The `Continuation` interface is very specific about suspending and resuming execution, so it is modeled as a callback interface, and Kotlin generates a default implementation for it with all the required machinery to do the jumps, coordinate the different suspension points, share data between them, and so on. The Compose use case is very different, since its goal is to create an in memory representation of a large call graph that can be optimized at runtime in different ways.

Once we understand the similarities between Composable and suspend functions, it can be interesting to reflect on the idea of “function coloring”.

## The color of Composable functions

Composable functions have different limitations and capabilities than standard functions. They have a different type (more on this later), and model a very specific concern. This differentiation can be understood as a form of “function coloring”, since somehow they represent a separate **category of functions**.

“Function coloring” is a concept explained by Bob Nystrom from the Dart team at Google in a blockpost called [“What color is your function?”](https://journal.stuffwithstuff.com/2015/02/01/what-color-is-your-function/), written in 2015. He explained how async and sync functions don’t compose well together, since you cannot call async functions from sync ones, unless you make the latter also async, or provide an awaiting mechanism that allows to call async functions and await for their result. This is why Promises and `async/await` were introduced by some libraries and languages. It was an attempt to bring composability back. Bob refers to these two function categories as two different “function colors”.

In Kotlin, `suspend` aims to solve the same problem. However, `suspend` functions are also colored, since we can only call `suspend` functions from other `suspend` functions. Composing programs with a mix of standard and `suspend` functions requires some ad-hoc integration mechanism (coroutine launch points). The integration is not transparent to the developer.

Overall, this limitation is expected. We are modeling two categories of functions that represent concepts of a very different nature. It’s like speaking two different languages. We have operations that are meant to calculate an immediate result (sync), and operations that unfold over time and eventually provide a result (async), which will likely take longer to complete.

In Jetpack Compose, the case of Composable functions is equivalent. We cannot call Composable functions from standard functions transparently. If we want to do that, an integration point is required (e.g: `Composition.setContent`). Composable functions have a completely different goal than standard functions. They are not designed to write program logics, but to describe changes for a node tree.

It might seem that I am tricking a bit here. One of the benefits of Composable functions is that you can declare UI using logics, actually. That means sometimes we need to call Composable functions from standard functions. For example:

```kotlin
1 @Composable
2 fun SpeakerList(speakers: List&lt;Speaker&gt;) {
3   Column {
4     speakers.forEach {
5       Speaker(it)
6     }
7   }
8 }
```

The `Speaker` Composable is called from the `forEach` lambda, and the compiler does not seem to complain. How is it possible to mix function colors this way then?

The reason is `inline`. Collection operators are declared as `inline`, so they inline their lambdas into their callers making it effectively as if there was no extra indirection. In the above example, the `Speaker` Composable call is inlined within the `SpeakerList` body, and that is allowed since both are Composable functions. By leveraging `inline` we can bypass the problem of function coloring to write the logic of our Composables. Our tree will be comprised of Composable functions only.

But, is coloring really a problem?

Well, it might be if we needed to combine both types of functions and jump from one to the other all the time. However, that is not the case either for `suspend` or `@Composable`. Both mechanisms require an integration point, and therefore we gain a completely colored call stack beyond that point (everything `suspend`, or Composable). This is actually an advantage, since it allows the compiler and runtime to treat colored functions differently, and enable more advanced language features that were not possible with standard functions.

In Kotlin, `suspend` allows to model async non-blocking programs in a very idiomatic and expressive manner. The language gains the ability to represent a very complex concept in an extremely simple way: adding a `suspend` modifier to our functions. On the other hand, `@Composable` makes standard functions become restartable, skippable, and reactive, which are capabilities that standard Kotlin functions do not have.

## Composable function types

The `@Composable` annotation effectively changes the type of the function at compile time. From a syntax perspective, the type of a Composable function is `@Composable (T) -> A`, where `A` can be `Unit`, or any other type if the function returns a value (e.g: `remember`). Developers can use that type to declare Composable lambdas as one would declare any standard lambda in Kotlin.

```kotlin
 1 // This can be reused from any Composable tree
 2 val textComposable: @Composable (String) -&gt; Unit = {
 3   Text(
 4     text = it,
 5     style = MaterialTheme.typography.subtitle1
 6   )
 7 }
 8 
 9 @Composable
10 fun NamePlate(name: String, lastname: String) {
11   Column(modifier = Modifier.padding(16.dp)) {
12     Text(
13       text = name,
14       style = MaterialTheme.typography.h6
15     )
16     textComposable(lastname)
17   }
18 }
```

Composable functions can also have the type `@Composable Scope.() -> A`, frequently used for scoping information to a specific Composable only:

```kotlin
 1 inline fun Box(
 2   ...,
 3   content: @Composable BoxScope.() -&gt; Unit
 4 ) {
 5   // ...
 6   Layout(
 7     content = { BoxScopeInstance.content() },
 8     measurePolicy = measurePolicy,
 9     modifier = modifier
10   )
11 }
```

From a language perspective, types exist to provide information to the compiler in order to perform quick static validation, sometimes generate some convenient code, and to delimit/refine how the data can be used at runtime. The `@Composable` annotation changes how a function is validated and used at runtime, and that is also why they are considered to have a different type than normal functions.