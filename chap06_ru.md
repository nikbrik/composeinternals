# 6. Эффекты и обработчики эффектов

Перед разбором обработчиков эффектов полезно вспомнить, что считается побочным эффектом — так будет яснее, почему важно держать их под контролем в composable-деревьях.

## Побочные эффекты

В главе 1 мы говорили о свойствах Composable-функций: побочные эффекты делают функции недетерминированными и мешают рассуждать о коде.

По сути побочный эффект — всё, что выходит из-под контроля и области видимости функции. Чистая функция «сложить два числа»:

```kotlin
1 fun add(a: Int, b: Int) = a + b
```
*Add.kt*

Это «чистая» функция: только входы и результат, результат не меняется при тех же входах — функция **детерминирована**.

Теперь добавим побочные действия:

```kotlin
1 fun add(a: Int, b: Int) =
2   calculationsCache.get(a, b) ?: 
3   (a + b).also { calculationsCache.store(a, b, it) }
4 }
```
*AddWithSideEffect.kt*

Вводим кэш вычислений; он выходит из-под контроля функции. Если кэш обновляется из другого потока:

```kotlin
1 fun main() {
2   add(1, 2) // 3
3   // Другой поток: cache.store(1, 2, res = 4)
4   add(1, 2) // 4
5 }
```
*AddWithSideEffect2.kt*

Функция перестаёт быть детерминированной. Итого: побочные эффекты усложняют рассуждения и тестирование. Примеры: глобальные переменные, кэш, БД, сеть, вывод, файлы.

## Побочные эффекты в Compose

При выполнении побочных эффектов внутри Composable мы попадаем в те же проблемы: эффект выходит из-под контроля жизненного цикла Composable. Любой Composable может перезапускаться многократно, поэтому запускать эффекты прямо в теле Composable рискованно (глава 1: Composable перезапускаемые).

Пример: Composable, загружающий данные из сети в теле:

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

Эффект будет выполняться при каждой recomposition, возможны множественные параллельные запросы без координации. Нужно выполнять эффект один раз при первой composition и хранить состояние на весь жизненный цикл Composable.

Другой пример — обновление внешнего состояния (включение/выключение TouchHandler в зависимости от состояния drawer):

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

Строка `drawerTouchHandler.enabled = drawerState.isOpen` — побочный эффект composition. Проблема: эффект выполняется при каждой composition/recomposition и **никогда не освобождается**, возможны утечки. Если Composable, запустивший сетевой запрос, выйдет из composition до завершения запроса, мы скорее всего захотим отменить задачу.

Jetpack Compose предлагает механизмы запуска побочных эффектов с учётом жизненного цикла: можно растянуть задачу на несколько recomposition или автоматически отменить при выходе Composable из composition. Эти механизмы называются **обработчиками эффектов (effect handlers)**.

## Что нам нужно

Composition может **выполняться в разных потоках**, параллельно или в разном порядке. Нужны механизмы, чтобы:

- Эффекты запускались на нужном шаге жизненного цикла Composable.
- Приостанавливающиеся эффекты выполнялись в подходящем контексте (корутины, `CoroutineContext`).
- Эффекты с захваченными ссылками могли освобождать их при выходе из composition.
- Текущие приостановленные эффекты отменялись при выходе из composition.
- Эффекты, зависящие от меняющегося ключа, автоматически отменялись/перезапускались при его изменении.

Всё это дают **обработчики эффектов** Jetpack Compose.

> Обработчики эффектов из поста доступны в `1.0.0-beta02` и позже. Публичный API Compose заморожен с момента входа в beta.

## Обработчики эффектов

Composable «входит» в composition при материализации на экране и «выходит» при удалении из дерева. Между этими событиями могут выполняться эффекты; некоторые могут переживать жизненный цикл Composable (растягиваться на несколько composition).

Две категории:

- **Неприостанавливающиеся эффекты:** например, инициализация колбэка при входе и его освобождение при выходе.
- **Приостанавливающиеся эффекты:** например, загрузка данных из сети для UI.

## Неприостанавливающиеся эффекты

### DisposableEffect

Побочный эффект жизненного цикла composition.

- Для эффектов, **требующих освобождения**.
- Запускается при первом входе и при каждом изменении ключей.
- Обязателен колбэк **onDispose**. Освобождение — при выходе из composition и при каждой recomposition с изменившимися ключами (тогда эффект освобождается и перезапускается).

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

Колбэк прикрепляется к диспетчеру из `CompositionLocal`. Чтобы эффект перезапускался при смене диспетчера, **передаём диспетчер как ключ**. При выходе Composable колбэк освобождается. Чтобы запустить эффект один раз при входе и освободить при выходе, можно **передать константу в качестве ключа**: `DisposableEffect(true)` или `DisposableEffect(Unit)`. У `DisposableEffect` всегда должен быть хотя бы один ключ.

### SideEffect

Ещё один побочный эффект composition. Особенность: «выполнить при этой composition или забыть» — при падении composition эффект **отбрасывается**. Он **не хранится в slot table**, не переживает composition и не перезапускается при следующих.

- Для эффектов **без необходимости освобождения**.
- Выполняется после каждой composition/recomposition.
- Удобен для **публикации обновлений во внешнее состояние**.

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

Так мы синхронизируем внешнее состояние (TouchHandler) с текущим состоянием drawer при каждой composition. `SideEffect` — для **публикации обновлений** во внешнее состояние, не управляемое системой Compose State.

### currentRecomposeScope

Скорее эффект, чем обработчик, но полезно упомянуть.

В Android вы могли сталкиваться с аналогом `invalidate` в системе View — он запускает новый проход measure/layout/draw. Раньше так часто делали покадровую анимацию на Canvas: на каждом кадре вызывали invalidate и рисовали с учётом прошедшего времени.

`currentRecomposeScope` — интерфейс с одной целью:

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

Вызов `currentRecomposeScope.invalidate()` инвалидирует composition локально и **запускает recomposition**. Полезно, когда источник истины **не snapshot State** Compose.

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

Здесь мы вручную инвалидируем при появлении результата, так как не используем `State`. Это крайний случай; в большинстве ситуаций лучше опираться на `State` и умную recomposition. Итого: ⚠️ использовать редко! ⚠️ Опирайтесь на `State` для умной recomposition при изменении данных — так вы максимально используете возможности Compose runtime.

> Для покадровой анимации в Compose есть API приостановки до следующего кадра Choreographer и обновления state по прошедшему времени — см. [официальную документацию по анимации](https://developer.android.com/jetpack/compose/animation#targetbasedanimation).

## Приостанавливающиеся эффекты

### rememberCoroutineScope

Создаёт `CoroutineScope`, привязанный к жизненному циклу composition.

- Для **приостанавливающихся эффектов, привязанных к жизненному циклу composition**.
- Scope **отменяется при выходе из composition**.
- Один и тот же scope возвращается при recomposition — можно продолжать запускать задачи; все они отменятся при выходе.
- Удобен для запуска задач **в ответ на действия пользователя**.
- Выполняется на диспетчере Applier при входе (обычно [`AndroidUiDispatcher.Main`](https://cs.android.com/androidx/platform/frameworks/support/+/androidx-main:compose/ui/ui/src/androidMain/kotlin/androidx/compose/ui/platform/AndroidUiDispatcher.android.kt)).

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

Каждое изменение ввода отменяет предыдущую задачу и запускает новую с задержкой — троттлинг на стороне UI.

> Отличие от `LaunchedEffect`: `LaunchedEffect` используют для задач, инициированных composition, а `rememberCoroutineScope` — для задач **по действию пользователя**.

### LaunchedEffect

Приостанавливающийся вариант для загрузки начального состояния при входе в composition.

- Запускается при входе в composition.
- Отменяется при выходе.
- Отменяется и перезапускается при изменении ключа/ключей.
- Удобен, чтобы **растянуть задачу на несколько recomposition**.
- Выполняется на диспетчере Applier при входе (обычно [`AndroidUiDispatcher.Main`](https://cs.android.com/androidx/platform/frameworks/support/+/androidx-main:compose/ui/ui/src/androidMain/kotlin/androidx/compose/ui/platform/AndroidUiDispatcher.android.kt)). **Требуется хотя бы один ключ.**

Эффект запускается один раз при входе и затем при каждом изменении ключа. Не забывайте: при перезапуске эффект каждый раз отменяется.

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

### produceState

Удобная обёртка над `LaunchedEffect` для случая, когда эффект в итоге заполняет `State`.

- Можно задать начальное значение и один или несколько ключей.
- Если ключ не передать, внутри вызывается `LaunchedEffect(Unit)` — эффект **растягивается на все composition**. API это явно не отражает.

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

## Адаптеры для сторонних библиотек

Часто нужно потреблять типы вроде `Observable`, `Flow`, `LiveData`. Compose даёт адаптеры; подключается соответствующая зависимость:

```kotlin
1 implementation &quot;androidx.compose.runtime:runtime:$compose_version&quot; // includes Flow \
2 adapter
3 implementation &quot;androidx.compose.runtime:runtime-livedata:$compose_version&quot;
4 implementation &quot;androidx.compose.runtime:runtime-rxjava2:$compose_version&quot;
```
*Dependencies.kt*

**Все адаптеры в итоге опираются на обработчики эффектов**: подписываются через API библиотеки и отображают каждый элемент в свой `MutableState`, экспонируемый как неизменяемый `State`.

Примеры: `LiveData.observeAsState()` (реализация через `DisposableEffect`), RxJava2 `subscribeAsState()` (аналогично), Kotlin Flow `collectAsState()` (через `produceState`/`LaunchedEffect`, так как Flow нужно собирать из приостанавливающегося контекста). Примеры для разных библиотек:

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

[Реализация](https://cs.android.com/androidx/platform/tools/dokka-devsite-plugin/+/master:testData/compose/source/androidx/compose/runtime/livedata/LiveDataAdapter.kt) `observeAsState` опирается на обработчик `DisposableEffect`.

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

[Реализация](https://cs.android.com/androidx/platform/tools/dokka-devsite-plugin/+/master:testData/compose/source/androidx/compose/runtime/rxjava2/RxJava2Adapter.kt) `subscribeAsState()` устроена аналогично. То же расширение доступно для `Flowable`.

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

[Реализация](https://cs.android.com/androidx/platform/tools/dokka-devsite-plugin/+/master:testData/compose/source/androidx/compose/runtime/SnapshotState.kt) `collectAsState` устроена иначе: `Flow` нужно собирать из приостанавливающегося контекста, поэтому используется `produceState`, который опирается на `LaunchedEffect`.

Все эти адаптеры опираются на обработчики эффектов из этой главы; по тому же паттерну можно написать свой адаптер для своей библиотеки.
