# 4. Compose UI

Когда говорят о Jetpack Compose, обычно имеют в виду всё вместе: компилятор, рантайм и Compose UI. В предыдущих главах мы разобрали компилятор и то, как он обеспечивает оптимизации и возможности рантайма, затем сам рантайм и то, как в нём сосредоточена основная механика Compose. Теперь очередь Compose UI — клиентской библиотеки для рантайма.

Краткое уточнение: в книге Compose UI выбран как пример клиентской библиотеки для Compose runtime, но есть и другие — например [Compose for Web](https://compose-web.ui.pages.jetbrains.team/) от JetBrains или [Mosaic](https://github.com/JakeWharton/mosaic) (консольный UI от Jake Wharton). Последняя глава книги как раз посвящена тому, как писать клиентские библиотеки для Jetpack Compose.

## Интеграция UI с Compose runtime

Compose UI — **Kotlin multiplatform** фреймворк. Он даёт строительные блоки и механику для эмитирования UI через Composable-функции. Кроме того, библиотека [включает Android- и Desktop-исходники](https://cs.android.com/androidx/platform/frameworks/support/+/androidx-main:compose/ui/ui/src/) с слоями интеграции для Android и Desktop.

JetBrains ведёт Desktop, Google — Android и общий код. И Android, и Desktop опираются на общий sourceset. Compose for Web пока вынесен из Compose UI и строится на DOM.

Цель интеграции UI с Compose runtime — построить дерево раскладки, которое пользователь видит на экране. Это дерево создаётся и обновляется выполнением Composable-функций, эмитирующих UI. Тип узла дерева известен только Compose UI, рантайм от него не зависит. Хотя Compose UI уже мультиплатформенный, его типы узлов пока поддерживаются только на Android и Desktop. Другие библиотеки (например Compose for Web) используют свои типы. Поэтому типы узлов, эмитируемые клиентской библиотекой, должны быть известны только ей, а рантайм делегирует ей вставку, удаление, перемещение и замену узлов. Подробнее — ниже в главе.

В построении и обновлении дерева раскладки участвуют первичная composition и последующие recomposition. Они выполняют наши Composable-функции, те планируют изменения (вставка, удаление, перемещение, замена узлов). Получается список изменений, который затем обходится с помощью `Applier`, чтобы превратить их в реальные изменения дерева для пользователя. При первичной composition изменения вставляют все узлы и строят дерево; при recomposition — обновляют его. Recomposition запускается при изменении входных данных Composable (параметры или читаемый mutable state).

В предыдущих главах мы бегло это затрагивали; эта глава развивает тему.

## От запланированных изменений к реальным изменениям дерева

При выполнении Composable во время composition или recomposition они эмитируют изменения. Плюс используется побочная таблица `Composition` (далее с заглавной буквы, чтобы отличать от процесса composition). В ней хранятся данные для отображения выполнения Composable (запланированных изменений) в фактические изменения дерева узлов.

В приложении на Compose UI может быть столько Composition, сколько деревьев узлов нужно представить. Пока мы не говорили, что Composition может быть несколько — но их действительно может быть несколько. Ниже мы разберём, как строится дерево раскладки и какие типы узлов используются.

## Composition с точки зрения Compose UI

Типичная точка входа из Compose UI в рантайм на Android — вызов `setContent`, например для экрана:

```kotlin
 1 class MainActivity : ComponentActivity() {
 2   override fun onCreate(savedInstanceState: Bundle?) {
 3     super.onCreate(savedInstanceState)
 4     setContent {
 5       MaterialTheme {
 6         Text(&quot;Hello Compose!&quot;)
 7       }
 8     }
 9   }
10 }
```
*MainActivity.kt*

Экран (Activity/Fragment) — не единственное место вызова `setContent`. Он может быть и внутри иерархии View, например через `ComposeView` (гибридное Android-приложение):

```kotlin
1 ComposeView(requireContext()).apply {
2   setContent {
3     MaterialTheme {
4       Text(&quot;Hello Compose!&quot;)
5     }
6   }
7 }
```
*ComposeView.setContent*

В примере view создаётся программно; он может быть и частью layout из XML.

**Функция `setContent` создаёт новую корневую Composition** и по возможности переиспользует её. Я называю их «корневыми», так как каждая размещает своё независимое composable-дерево. Эти composition между собой не связаны. Сложность каждой зависит от представляемого UI.

В приложении может быть несколько деревьев узлов, каждое со своей Composition. Пример: приложение с тремя Fragment (см. рисунок). Fragment 1 и 3 вызывают `setContent` для своих composable-деревьев, Fragment 2 объявляет несколько `ComposeView` в layout и вызывает `setContent` для каждого. В итоге — 5 корневых Composition, все независимы.

![](resources/multiple_root_compositions.png)
*Несколько корневых Composition*

Для построения любой из этих иерархий связанный `Composer` запускает процесс composition. Выполняются все Composable внутри соответствующего вызова `setContent`, они эмитируют изменения. В Compose UI это изменения вставки, перемещения или замены UI-узлов, эмитируемые обычными UI-блоками: `Box`, `Column`, `LazyColumn` и т.д. Хотя они часто из разных библиотек (`foundation`, `material`), все в итоге определены как `Layout` (`compose-ui`) и эмитируют один тип узла — `LayoutNode`.

`LayoutNode` уже упоминался в предыдущей главе — представление UI-блока и самый частый тип узла для корневой Composition в Compose UI.

Любой Composable `Layout` эмитирует узел `LayoutNode` в composition через `ReusableComposeNode` (контракт `ComposeUiNode` реализован у `LayoutNode`):

```kotlin
 1 @Composable inline fun Layout(
 2     content: @Composable () -&gt; Unit,
 3     modifier: Modifier = Modifier,
 4     measurePolicy: MeasurePolicy
 5 ) {
 6   val density = LocalDensity.current
 7   val layoutDirection = LocalLayoutDirection.current
 8   val viewConfiguration = LocalViewConfiguration.current
 9     
10   // Emits a LayoutNode!
11   ReusableComposeNode&lt;ComposeUiNode, Applier&lt;Any&gt;&gt;(
12     factory = { LayoutNode() },
13     update = {
14       set(measurePolicy, { this.measurePolicy = it })
15       set(density, { this.density = it })
16       set(layoutDirection, { this.layoutDirection = it })
17       set(viewConfiguration, { this.viewConfiguration = it })
18     },
19     skippableUpdate = materializerOf(modifier),
20     content = content
21   )
22 }
```
*Layout.kt*

Так эмитируется изменение на вставку или обновление переиспользуемого узла в composition. То же происходит для любых UI-блоков.

Переиспользуемые узлы — оптимизация рантайма Compose. При смене `key` узла Composer может перезапустить контент узла (обновить на месте при recomposition), а не отбрасывать и создавать новый. Для этого composition ведёт себя как при создании нового контента, но slot table обходится как при recomposition. Оптимизация возможна только для узлов, полностью описываемых операциями `set` и `update` в вызове эмитирования, то есть без скрытого внутреннего состояния. Это верно для `LayoutNode`, но не для `AndroidView` — поэтому `AndroidView` использует обычный `ComposeNode`.

`ReusableComposeNode` создаёт узел (через `factory`), инициализирует его (лямбда `update`) и создаёт replaceable group вокруг всего контента. Группе присваивается уникальный ключ. Всё, что эмитируется при вызове лямбды `content` внутри replaceable group, становится дочерними узлами этого узла.

Вызовы `set` в блоке `update` планируют выполнение своих лямбд только при первом создании узла или при изменении значения соответствующего свойства с момента последнего запоминания.

Так `LayoutNode` попадают в каждую из множественных Composition приложения. Может показаться, что в Composition только они — но нет. Есть и другие типы Composition и узлов; об этом — ниже.

## Subcomposition с точки зрения Compose UI

Composition существуют не только на корневом уровне. Composition может создаваться глубже в composable-дереве и связываться с родительской. Это **Subcomposition** (подчинённая composition). Мы уже видели, что composition связаны в дерево: у каждой есть ссылка на родительский `CompositionContext` (у корневой родитель — сам `Recomposer`). Так рантайм обеспечивает разрешение и распространение `CompositionLocal` и инвалидаций вниз по дереву, как будто это одна composition.

В Compose UI Subcomposition создают в основном по двум причинам:

- Отложить первичную composition до момента, когда известна некоторая информация.
- Сменить тип узла, порождаемого поддеревом.

### Отложенная первичная composition

Пример — `SubcomposeLayout`, аналог `Layout`, который создаёт и запускает отдельную composition на фазе layout. Дочерние Composable могут зависеть от значений, вычисленных в нём. `SubcomposeLayout` используется, например, в `BoxWithConstraints`, который передаёт в блок ограничения родителя, чтобы контент мог от них зависеть. В примере из официальной документации `BoxWithConstraints` выбирает между двумя разными composable в зависимости от доступной `maxHeight`:

```kotlin
 1 BoxWithConstraints {
 2   val rectangleHeight = 100.dp
 3   if (maxHeight &lt; rectangleHeight * 2) {
 4     Box(Modifier.size(50.dp, rectangleHeight).background(Color.Blue))
 5   } else {
 6     Column {
 7       Box(Modifier.size(50.dp, rectangleHeight).background(Color.Blue))
 8       Box(Modifier.size(50.dp, rectangleHeight).background(Color.Gray))
 9     }
10   }
11 }
```
*BoxWithConstraints Sample*

Создатель Subcomposition решает, когда выполнять первичную composition; `SubcomposeLayout` делает это на фазе layout, а не при композировании корня.

Subcomposition позволяет перезапускать composition независимо от родителя. В `SubcomposeLayout` при каждом layout параметры лямбды могут меняться — тогда запускается recomposition. С другой стороны, при изменении состояния, читаемого в subcomposition, после выполнения первичной composition планируется recomposition родительской Composition.

По типу узлов `SubcomposeLayout` тоже эмитирует `LayoutNode`, то есть тип узлов поддерева совпадает с родительской Composition. Возникает вопрос: можно ли в одной Composition поддерживать разные типы узлов?

Технически да, если соответствующий `Applier` это допускает — всё упирается в то, что считать типом узла. Если тип общий для нескольких подтипов, разные типы возможны, хотя логика Applier может усложниться. В Compose UI реализации Applier зафиксированы на одном типе узла.

Subcomposition как раз позволяет **использовать в поддереве совершенно другой тип узла** — второй из перечисленных сценариев.

### Смена типа узла в поддереве

Пример в Compose UI — composable для векторной графики (например `rememberVectorPainter`).

Векторные Composable — хороший кейс: они тоже создают свою Subcomposition и представляют вектор как дерево. При композировании векторный Composable эмитирует в свою Subcomposition другой тип узла — `VNode`, рекурсивный тип для отдельных Path или групп Path.

```kotlin
1 @Composable
2 fun MenuButton(onMenuClick: () -&gt; Unit) {
3   Icon(
4     painter = rememberVectorPainter(image = Icons.Rounded.Menu),
5     contentDescription = &quot;Menu button&quot;,
6     modifier = Modifier.clickable { onMenuClick() }
7   )
8 }
```
*Vector painter example*

Обычно векторы рисуют через `VectorPainter` внутри `Image`, `Icon` или подобного Composable — то есть охватывающий Composable это `Layout` и эмитирует `LayoutNode` в свою Composition. При этом `VectorPainter` создаёт свою Subcomposition для вектора и связывает её с этой Composition как с родительской. Схема:

![](resources/composition_and_subcomposition.png)
*Composition и Subcomposition*

Так поддерево вектора (Subcomposition) использует другой тип узла — `VNode`.

Векторы моделируются через Subcomposition, чтобы из блока векторного Composable (например `rememberVectorPainter`) можно было обращаться к части `CompositionLocal` родительской Composition (цвета темы, density и т.д.).

Subcomposition для векторов освобождается, когда соответствующий `VectorPainter` выходит из родительской Composition (когда выходит и охватывающий его Composable). Подробнее о жизненном цикле Composable — в одной из следующих глав.

Итак, картина того, как выглядит дерево в типичном приложении Compose UI (Android или Desktop), с корневыми Composition и Subcomposition, яснее. Дальше — вторая сторона интеграции с платформой: материализация изменений для отображения на экране.

## Отражение изменений в UI

Мы разобрали, как UI-узлы эмитируются и передаются в рантайм при первичной composition и recomposition. Дальше рантайм выполняет свою работу (глава 3). Но это только одна сторона — нужна интеграция, чтобы все эти изменения отразились в реальном UI. Этот процесс часто называют «материализацией» дерева узлов; за него отвечает клиентская библиотека, здесь Compose UI. Подробнее — ниже.

## Разные типы Applier

Ранее мы описали `Applier` как абстракцию, через которую рантайм в итоге материализует изменения дерева. Это инвертирует зависимости: рантайм не привязан к платформе. Клиентские библиотеки вроде Compose UI подключают свои реализации `Applier` и **выбирают свои типы узлов** для интеграции с платформой. Схема:

![](resources/applier.png)
*Архитектура Compose*

*Верхние два блока (Applier и AbstractApplier) — часть Compose runtime. Нижние — примеры реализаций из Compose UI.*

`AbstractApplier` — базовая реализация от Compose runtime с общей логикой. В ней **посещённые** узлы хранятся в `Stack` и ведётся ссылка на текущий узел. При спуске по дереву Composer уведомляет Applier вызовом `applier#down(node: N)` — узел кладётся в стек. При подъёме вызывается `applier#up()`, с вершины стека снимается последний узел.

Пример: дерево для материализации:

```kotlin
 1 Column {
 2   Row {
 3     Text(&quot;Some text&quot;)
 4     if (condition) {
 5       Text(&quot;Some conditional text&quot;)
 6     }
 7   }
 8   if (condition) {
 9     Text(&quot;Some more conditional text&quot;)
10   }
11 }
```
*AbstractApplier example*

При изменении `condition` Applier получит: `down` для Column; затем `down` для Row; затем delete (или insert) для условного Text; затем `up` обратно к Column; наконец delete (или insert) для второго условного текста.

Стек и операции `down`/`up` вынесены в `AbstractApplier`, чтобы разные applier разделяли одну и ту же логику навигации независимо от типа узлов. Связь родитель–потомок при этом обеспечивается, и конкретные типы узлов при необходимости могут хранить её сами — как `LayoutNode`, у которого не все операции выполняются во время composition (например, при перерисовке узла Compose UI поднимается по родителям, чтобы найти узел с нужным слоем и вызвать invalidate).

Напоминание из главы 3: дерево узлов можно строить **сверху вниз** или **снизу вверх**, с разными последствиями по производительности в зависимости от числа уведомляемых узлов при вставке. В Compose UI есть примеры обеих стратегий — две реализации `Applier`:

- **`UiApplier`**: для большей части Android UI; тип узла — `LayoutNode`.
- **`VectorApplier`**: для векторной графики; тип узла — `VNode`.

Для корневой Composition с `LayoutNode` и Subcomposition с `VNode` используются оба applier.

`UiApplier` вставляет узлы снизу вверх, чтобы избежать дублирующих уведомлений (схема из главы 2: сначала вставка A и C в B, затем дерева B в R — уведомляется только непосредственный родитель). Для Android UI с глубокой вложенностью это важно.

`VectorApplier` строит дерево сверху вниз. При вставке нового узла пришлось бы уведомлять всех предков, но для векторной графики уведомления никому не нужны — обе стратегии равнозначны. При вставке ребёнка в `VNode` уведомляется только слушатель этого узла.

## Материализация нового LayoutNode

Упрощённый `UiApplier` из Compose UI:

```kotlin
 1 internal class UiApplier(
 2     root: LayoutNode
 3 ) : AbstractApplier&lt;LayoutNode&gt;(root) {
 4 
 5   override fun insertTopDown(index: Int, instance: LayoutNode) {
 6     // Ignored. (The tree is built bottom-up with this one).
 7   }
 8 
 9   override fun insertBottomUp(index: Int, instance: LayoutNode) {
10     current.insertAt(index, instance)
11   }
12 
13   override fun remove(index: Int, count: Int) {
14     current.removeAt(index, count)
15   }
16 
17   override fun move(from: Int, to: Int, count: Int) {
18     current.move(from, to, count)
19   }
20 
21   override fun onClear() {
22     root.removeAll()
23   }
24   ...
25 }
```
*UiApplier.android.kt*

Тип узла зафиксирован как `LayoutNode`; все операции вставки, удаления и перемещения делегируются текущему посещаемому узлу. `LayoutNode` — чистый Kotlin-класс без зависимостей от Android, модель UI-узла для нескольких платформ (Android, Desktop). Он хранит список детей и операции вставки/удаления/перемещения. Узлы связаны в дерево, у каждого есть ссылка на родителя, все привязаны к одному `Owner`. Схема иерархии:

![](resources/layoutnode_tree.png)
*Дерево LayoutNode*

`Owner` — абстракция для интеграции с платформой. На Android это `View` (`AndroidComposeView`) — связь composable-дерева (`LayoutNode`) с системой View. При присоединении, откреплении, переупорядочивании, перемерке или обновлении узла через Owner можно вызвать invalidate (через API View), и изменения отобразятся при следующей отрисовке.

Упрощённо: как новый узел вставляется и материализуется в `LayoutNode#insertAt`:

```kotlin
 1 internal fun insertAt(index: Int, instance: LayoutNode) {
 2   check(instance._foldedParent == null) {
 3     &quot;Cannot insert, it already has a parent!&quot;
 4   }
 5   check(instance.owner == null) {
 6     &quot;Cannot insert, it already has an owner!&quot;
 7   }
 8 
 9   instance._foldedParent = this
10   _foldedChildren.add(index, instance)
11   onZSortedChildrenInvalidated()
12 
13   instance.outerLayoutNodeWrapper.wrappedBy = innerLayoutNodeWrapper
14 
15   val owner = this.owner
16   if (owner != null) {
17     instance.attach(owner)
18   }
19 }
```
*LayoutNode#insertAt.kt*

После проверок текущий узел задаётся родителем вставляемого, новый узел добавляется в список детей, инвалидируется список детей, отсортированных по Z-index (параллельный список для порядка отрисовки). Затем связываются outer и inner `LayoutNodeWrapper` (подробнее в разделе об измерении). В конце узел присоединяется к тому же `Owner`, что и родитель. Упрощённо `attach`:

```kotlin
 1 internal fun attach(owner: Owner) {
 2   check(_foldedParent == null || _foldedParent?.owner == owner) {
 3     &quot;Attaching to a different owner than the parent&#39;s owner&quot;
 4   }
 5   val parent = this.parent // [this] is the node being attached
 6   
 7   this.owner = owner
 8   
 9   if (outerSemantics != null) {
10     owner.onSemanticsChange()
11   }
12   owner.onAttach(this)
13   _foldedChildren.forEach { child -&gt;
14     child.attach(owner)
15   }
16 
17   requestRemeasure()
18   parent?.requestRemeasure()
19 }
```
*LayoutNode#attach.kt*

Здесь проверяется, что у всех дочерних узлов тот же Owner, что у родителя; `attach` вызывается рекурсивно по детям. Затем назначается owner, при наличии семантики уведомляется Owner, запрашивается перемерка для нового узла и родителя — через Owner это приводит к вызову `invalidate`/`requestLayout` и в итоге к появлению узла на экране.

## Замыкание цикла

Owner присоединяется к иерархии View при вызове `setContent` в Activity, Fragment или ComposeView — этого не хватало для полной картины.

Кратко по шагам: при `Activity#setContent` создаётся и присоединяется `AndroidComposeView`. При вызове Applier’ом `current.insertAt(index, instance)` для вставки `LayoutNode(C)` новый узел присоединяется и запрашивает перемерку себя и родителя через Owner. Обычно вызывается `AndroidComposeView#invalidate`. Несколько инвалидаций одного View между кадрами просто помечают его как «грязный» — перерисовка будет одна. Затем вызывается `AndroidComposeView#dispatchDraw`: там выполняется перемерка и layout запрошенных узлов, затем отрисовка от корневого `LayoutNode`. Узлы всегда сначала измеряются, затем раскладываются, затем рисуются.

## Материализация удаления узлов

Удаление одного или нескольких дочерних узлов устроено похоже. `UiApplier` вызывает `current.removeAt(index, count)`. Родитель перебирает удаляемых детей (с конца), для каждого удаляет ребёнка из списка, инвалидирует Z-список и открепляет ребёнка и всех его потомков (owner = null), запрашивает перемерку родителя. Owner уведомляется при изменении семантики.

## Материализация перемещения узлов

То есть переупорядочивание детей. При `current.move(from, to, count)` узлы сначала удаляются через `removeAt`, затем вставляются в новую позицию, запрашивается перемерка родителя.

## Материализация очистки всех узлов

Аналогично удалению нескольких узлов: перебор всех детей (с конца), открепление каждого и запрос перемерки родителя.

## Измерение в Compose UI

Мы уже знаем, как и когда запрашивается перемерка. Пора разобраться, как измерение реально выполняется.

Любой `LayoutNode` может запросить перемерку через `Owner` — например при присоединении, откреплении или перемещении дочернего узла. View (`Owner`) помечается как «грязный» (`invalidate`), а узел попадает в **список узлов для перемерки и переразметки**. В следующем проходе отрисовки вызывается `AndroidComposeView#dispatchDraw` (как для любого инвалидированного `ViewGroup`), и `AndroidComposeView` перебирает список и через делегат выполняет нужные действия.

Для каждого узла из списка выполняются 3 шага (в таком порядке):

1. Проверка, нужна ли перемерка узла, и при необходимости — выполнение перемерки.
2. После измерения — проверка, нужна ли переразметка, и при необходимости — выполнение переразметки.
3. Проверка, есть ли отложенные запросы измерения для каких-либо узлов; при наличии — постановка их в список на следующий проход (возврат к шагу 1). Запросы перемерки откладываются, если они возникают уже во время текущего прохода измерения.

При измерении узла (шаг 1) делегат — внешний `LayoutNodeWrapper`. У каждого `LayoutNode` есть внешний и внутренний wrapper’ы. Внешний отвечает за измерение и отрисовку текущего узла, внутренний — за то же для его детей. Если в результате измерения размер узла изменился и у узла есть родитель, запрашивается перемерка или переразметка родителя.

При вставке узла (`LayoutNode#insertAt`, вызываемом `UiApplier`) выставляется связь между wrapper’ами:

```kotlin
1 internal fun insertAt(index: Int, instance: LayoutNode) {
2   ...
3   instance.outerLayoutNodeWrapper.wrappedBy = innerLayoutNodeWrapper
4   ...
5 }
```
*LayoutNode#insertAt.kt*

У узла могут быть модификаторы, и они тоже **влияют на измерение**, поэтому при измерении нужно учитывать цепочку. **Modifier — вещь без состояния**, поэтому состояние (в т.ч. измеренный размер) хранится в wrapper’ах. У `LayoutNode` есть не только внешний и внутренний wrapper’ы, но и по wrapper’у на каждый модификатор; все они выстроены в цепочку и обрабатываются по порядку. Wrapper модификатора хранит измеренный размер и другие вещи (например, отрисовку для `Modifier.drawBehind()`, hit-test). Схема связи wrapper’ов:

![](resources/modifier_resolution.png)
*Разрешение модификаторов при измерении*

Связь wrapper’ов: родитель через свой `measurePolicy` измеряет внешний wrapper каждого ребёнка; внешний wrapper оборачивает первый модификатор, тот — второй, и т.д., до внутреннего wrapper’а; внутренний снова использует `measurePolicy` текущего узла для измерения детей. Так обеспечивается порядок измерения с учётом модификаторов. С Compose 1.2 в цепочку попадают только `LayoutModifier`; для остальных типов используются обёртки. При отрисовке на последнем шаге внутренний wrapper перебирает детей по Z-индексу и вызывает у каждого draw.

При присоединении нового узла уведомляются все `LayoutNodeWrapper` (у них есть жизненный цикл). При запросе перемерки узла действие передаётся его внешнему `LayoutNodeWrapper`, который использует measure policy родителя; затем по цепочке перемеряются модификаторы и в конце внутренний wrapper перемеряет детей через measure policy текущего узла. Чтения mutable state внутри measure-lambda (measure policy) записываются — при изменении этого state lambda выполнится снова. После измерения новый размер сравнивается с предыдущим и при изменении запрашивается перемерка родителя.

## Политики измерения (Measuring policies)

Когда узел нужно измерить, соответствующий `LayoutNodeWrapper` опирается на политику измерения, переданную при эмиссии узла. В `Layout` политика передаётся снаружи; `LayoutNode` не привязан к конкретной политике. При смене политики запрашивается перемерка. Политики — это лямбда, которую передают в кастомный `Layout`; см. [официальную документацию по кастомным лейаутам](https://developer.android.com/jetpack/compose/layouts/custom).

Пример — `Spacer`:

```kotlin
 1 @Composable inline fun Layout(
 2   content: @Composable () -&gt; Unit,
 3   modifier: Modifier = Modifier,
 4   measurePolicy: MeasurePolicy
 5 ) {
 6   ...
 7   ReusableComposeNode&lt;ComposeUiNode, Applier&lt;Any&gt;&gt;(
 8     factory = { LayoutNode() },
 9     update = {
10       set(measurePolicy, { this.measurePolicy = it })
11       ...
12     },
13     skippableUpdate = materializerOf(modifier),
14     content = content
15   )
16 }
```
*Layout.kt*

```kotlin
 1 @Composable
 2 fun Spacer(modifier: Modifier) {
 3   Layout({}, modifier) { _, constraints -&gt;
 4     with(constraints) {
 5       val width = if (hasFixedWidth) maxWidth else 0
 6       val height = if (hasFixedHeight) maxHeight else 0
 7       layout(width, height) {}
 8     }
 9   }
10 }
```
*Spacer.kt*

Ещё пример — `Box`: политика зависит от выравнивания и от `propagateMinConstraints`; много компонентов построены поверх Box. Если детей нет — размер по min ограничениям. Один ребёнок: если не match parent — измеряем его, размер Box по ребёнку; если match parent — размер Box по min ограничениям, ребёнок с фиксированными ограничениями. Несколько детей: сначала измеряются все не-match-parent, считаются boxWidth/boxHeight; затем match-parent дети с ограничениями (boxWidth, boxHeight); в конце layout и размещение через placeInBox. Подробности — в исходниках `Box` и [документации](https://developer.android.com/jetpack/compose/layouts/custom).

## Внутренние измерения (Intrinsic measurements)

`MeasurePolicy` содержит методы для вычисления внутреннего (intrinsic) размера лейаута — ориентировочного размера при отсутствии ограничений. Внутренние измерения нужны, когда размер ребёнка нужно оценить до измерения (например, выровнять высоту по самому высокому соседу). Двойное измерение в Compose запрещено. У `LayoutNode` есть политика внутренних измерений, зависящая от measure policy. Она даёт: `minIntrinsicWidth(height)`, `minIntrinsicHeight(width)`, `maxIntrinsicWidth(height)`, `maxIntrinsicHeight(width)` — всегда нужна противоположная размерность. Пример: `Modifier.width(IntrinsicSize.Max)` — ширина по максимальной внутренней ширине; так в `DropdownMenuContent` делают ширину колонки по самому широкому пункту меню.

![](resources/dropdownmenu.png)
*Dropdown Menu*

Подробнее: [документация по intrinsic measurements](https://developer.android.com/jetpack/compose/layouts/intrinsic-measurements).

## Ограничения лейаута (Layout Constraints)

Ограничения приходят от родительского `LayoutNode` или модификатора: min/max по ширине и высоте в пикселях. Измеренные дети должны попадать в эти границы. Многие лейауты передают ограничения детям без изменений или с нулевым min. Родитель может передать бесконечные max (`Constraints.Infinity`) по одной оси — тогда ребёнок сам выбирает размер по этой оси (например, `LazyColumn` даёт бесконечную высоту). При фиксированном размере выставляют minWidth == maxWidth и minHeight == maxHeight. Пример: `LazyVerticalGrid` задаёт детям фиксированную ширину по числу колонок. `Constraints` смоделированы как inline-класс с одной `Long` и битовыми масками.

## LookaheadLayout

![](resources/lookaheadlayout.png)
*LookaheadLayout*

![](resources/lookaheadlayout2.png)
*LookaheadLayout*

`LookaheadLayout` связан с измерением и разметкой: позволяет заранее узнать целевые размеры и позиции при смене состояния (например, для shared element transitions). В [твите Doris Liu](https://twitter.com/doris4lt/status/1531364543305175041) показаны анимации перехода между состояниями. Работа: во время composition вычисляется «lookahead»-разметка; на её основе можно анимировать переход от текущих размеров/позиций к целевым. Внутри — отдельный проход измерения для lookahead-дерева; детали см. в исходниках и докладах по LookaheadLayout.

### Ещё один способ предрасчёта лейаутов

Lookahead даёт альтернативный способ заранее вычислить разметку.

### Как это устроено

Описание механизма lookahead-измерения и применения результатов.

### Внутренности LookaheadLayout

Детали реализации lookahead-дерева и его связи с основным деревом узлов.

### Дополнительные аспекты

Нюансы и граничные случаи при использовании LookaheadLayout.

## Моделирование цепочек модификаторов

Модификаторы образуют цепочку; каждый узел хранит список модификаторов. При применении к `LayoutNode` цепочка обходится и для каждого модификатора создаётся или переиспользуется wrapper. Порядок обхода определяет порядок измерения и отрисовки (например, padding, затем background). Подробности — в разделах про установку модификаторов на `LayoutNode` и их «поглощение» узлом.

## Установка модификаторов на LayoutNode и отрисовка дерева узлов

Модификаторы передаются в узел через materializer; каждый модификатор сопоставляется с соответствующим `LayoutNodeWrapper`. При изменении цепочки модификаторов узлы wrapper’ов пересоздаются или обновляются. Отрисовка: при вызове draw на узле обходится цепочка wrapper’ов; каждый wrapper может рисовать до или после детей (drawBehind / drawContent / drawFront). Дерево рисуется в порядке Z-индекса детей.

## Семантика в Jetpack Compose

Семантическое дерево описывает смысл UI для тестов и accessibility. Узлы семантики создаются для composable’ов и модификаторов с семантическими свойствами (`semantics`, `Modifier.clickable` и т.д.). Компоненты из библиотек `material` и `foundation` обычно уже подключают семантику неявно; в кастомных `Layout` семантику нужно задавать явно. Accessibility и тестирование **должны быть приоритетом**. Подробнее: [официальная документация по семантике](https://developer.android.com/jetpack/compose/semantics).

## Уведомление об изменениях семантики

Изменения семантики передаются в Android SDK через `Owner`. Библиотека AndroidX Core добавляет `AccessibilityDelegateCompat` для единообразной работы с accessibility на разных версиях системы. `Owner` иерархии `LayoutNode` использует реализацию этого делегата. Реализация обращается к системным accessibility-сервисам через `Context` из `Owner`. При уведомлении об изменении семантики через `Owner` в main looper через `Handler` откладывается проверка изменений в семантическом дереве. Действия по порядку: (1) Сравнение старого и нового дерева на структурные изменения (добавление/удаление детей); при их обнаружении делегат через conflated `Channel` уведомляет сервисы (код уведомления — suspend-функция в корутине, обрабатывающая изменения батчами раз в 100ms). (2) Сравнение на изменение свойств узлов; при изменении свойств — уведомление через `ViewParent#requestSendAccessibilityEvent`. (3) Обновление списка предыдущих семантических узлов текущими.

## Объединённое и необъединённое семантические деревья

В Jetpack Compose есть два семантических дерева: **объединённое (merged)** и **необъединённое (unmerged)**. Иногда группу composable’ов имеет смысл объединить в один семантический узел (например, чтобы TalkBack читал целую строку списка, а не каждый элемент по отдельности). Объединение задаётся свойством `mergeDescendants` у узла семантики. Объединённое дерево выполняет слияние согласно `mergeDescendants`; необъединённое хранит узлы раздельно. Инструменты выбирают, какое дерево использовать. Семантические свойства имеют политику слияния (merge policy). Например, для `contentDescription` при слиянии значения потомков добавляются в список. Ключи свойств задаются типобезопасно и требуют имя и политику слияния. Политика по умолчанию — не сливать, сохранять значение родителя при наличии. Подробности API — в [документации по семантике](https://developer.android.com/jetpack/compose/semantics).
