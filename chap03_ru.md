# 3. Compose runtime

Недавно [я опубликовал в Twitter краткое описание внутренней работы архитектуры Compose](https://twitter.com/JorgeCastilloPr/status/1390928660862017539) — взаимодействие UI, компилятора и рантайма.

![](resources/tweet.png)
*Твит об архитектуре Compose*

Эта ветка может послужить введением в главу: она даёт общий обзор важных моментов. Глава посвящена Jetpack Compose runtime и закрепляет понимание того, как части Compose взаимодействуют. При желании можно сначала прочитать тред в Twitter.

В нём объясняется, как Composable-функции **эмитируют** изменения в Composition, чтобы обновить его актуальной информацией, и как это происходит через внедрённый экземпляр `$composer` благодаря компилятору (глава 2). Вызов получения текущего `Composer` и сама Composition — часть Jetpack Compose runtime.

Тред намеренно остаётся на поверхности — Twitter не лучшее место для глубокого разбора. В книге мы как раз углубимся.

До сих пор мы называли состояние в памяти рантайма «Composition» — намеренно упрощённо. Начнём с структур данных для хранения и обновления состояния Composition.

## Slot table и список изменений

Различие между этими двумя структурами часто путают, во многом из‑за нехватки литературы о внутреннем устройстве Compose. Сейчас важно прояснить это в первую очередь.

Slot table — оптимизированная in-memory структура, в которой рантайм хранит **текущее состояние Composition**. Она заполняется при первичной composition и обновляется при каждой recomposition. Можно представить её как след всех вызовов Composable-функций: расположение в исходниках, параметры, запомненные значения, `CompositionLocal` и т.д. Всё, что произошло во время composition, хранится там. Эта информация потом используется `Composer` для построения следующего списка изменений — любые изменения дерева зависят от текущего состояния Composition.

Slot table фиксирует состояние; список изменений (change list) — то, что реально меняет дерево узлов. Его можно понимать как патч: после применения дерево обновляется. Все нужные изменения записываются, затем применяются. Применение списка изменений — задача `Applier`, абстракции, через которую рантайм в итоге материализует дерево. Подробнее — ниже.

Наконец, `Recomposer` координирует процесс: когда и в каком потоке выполнять recomposition и когда применять изменения. Об этом тоже ниже.

## Slot table подробнее

Разберём, как хранится состояние Composition. Slot table оптимизирована для быстрого линейного доступа и основана на идее «gap buffer», распространённой в текстовых редакторах. Данные хранятся в двух линейных массивах: в одном — информация о **группах** в Composition, в другом — **слоты** каждой группы.

```kotlin
1 var groups = IntArray(0)
2   private set
3   
4 var slots = Array&lt;Any?&gt;(0) { null }
5   private set
```
*LinearStructures.kt*

В главе 2 мы видели, как компилятор оборачивает тела Composable-функций, чтобы они эмитировали группы. Группы задают идентичность Composable в памяти (уникальный ключ) для последующей идентификации. Группы оборачивают информацию о вызове Composable и его потомках и указывают, как обрабатывать Composable (как группу). Тип группы зависит от паттернов управления потоком в теле: restartable, movable, replaceable, reusable…

Массив `groups` хранит значения `Int` — только «поля групп» (метаданные). Родительские и дочерние группы хранятся в виде полей групп. Так как структура линейная, поля родителя идут первыми, затем поля всех детей. Так моделируется дерево групп с упором на линейный обход. Случайный доступ дорог, кроме как через anchor группы. `Anchor` — по сути указатели для быстрого доступа.

Массив `slots` хранит данные для каждой группы. Тип значений — `Any?`, так как нужно хранить любую информацию. Здесь лежат реальные данные Composition. Каждая группа в `groups` описывает, как найти и интерпретировать её слоты в `slots` — группа связана с диапазоном слотов.

Slot table использует «gap» для чтения и записи — диапазон позиций в таблице. Gap перемещается и определяет, откуда читать и куда писать в массивах. У gap есть указатель начала записи; начало и конец могут сдвигаться, так что данные в таблице можно перезаписывать.

![](resources/slot_table_gap.png)
*Схема slot table*

Пример условной логики:

```kotlin
1 @Composable
2 @NonRestartableComposable
3 fun ConditionalText() {
4   if (a) {
5     Text(a)
6   } else {
7     Text(b)
8   }
9 }
```
*ConditionalNonRestartable.kt*

Так как этот Composable помечен как **non-restartable**, вставляется replaceable group (вместо restartable). Группа хранит в таблице данные текущего «активного» потомка — при `a == true` это `Text(a)`. При смене условия gap возвращается к началу группы и запись идёт оттуда, перезаписывая слоты данными для `Text(b)`.

Для чтения и записи используются `SlotReader` и `SlotWriter`. У slot table может быть несколько активных читателей, но **только один активный писатель**. После каждой операции чтения/записи соответствующий reader/writer закрывается. Одновременно может быть открыто любое число читателей, но читать можно **только когда не идёт запись**. `SlotTable` считается невалидной, пока активный writer не закрыт — он напрямую меняет группы и слоты, одновременное чтение могло бы привести к гонкам.

Reader работает как **посетитель**: отслеживает текущую группу в массиве groups, её начало и конец, родителя (хранится сразу перед ней), текущий слот группы, количество слотов и т.д. Умеет перепозиционироваться, пропускать группы, читать значение текущего слота и по индексам. Иными словами, используется для чтения информации о группах и слотах из массивов.

Writer записывает группы и слоты в массивы. Как сказано выше, в таблицу можно записывать данные любого типа (`Any?`). `SlotWriter` опирается на **gap** для групп и слотов, чтобы определять позиции записи в массивах.

Gap — **перемещаемый и изменяемый по размеру диапазон позиций** в линейном массиве. Writer хранит начало, конец и длину каждого gap и может перемещать gap, обновляя эти позиции.

Writer может добавлять, заменять, перемещать и удалять группы и слоты — например, добавлять новый узел Composable в дерево или заменять Composable при смене условия. Он может пропускать группы и слоты, продвигаться на заданное число позиций, переходить к позиции по `Anchor` и т.д.

Writer ведёт список `Anchor` для быстрого доступа по индексам. Позиция каждой группы (group index) в таблице тоже отслеживается через `Anchor`; anchor обновляется при перемещении, замене, вставке или удалении групп перед указываемой позицией.

Slot table также выступает итератором по группам composition для инструментов, инспектирующих Composition.

Пора перейти к списку изменений.

Подробнее о slot table — в [посте Лиланда Ричардсона](https://medium.com/androiddevelopers/under-the-hood-of-jetpack-compose-part-2-of-2-37b2c20c6cdd) из команды Jetpack Compose.

## Список изменений

Мы разобрали slot table и то, как рантайм отслеживает текущее состояние Composition. Какова тогда роль списка изменений? Когда он создаётся? Что моделирует? Когда изменения применяются и зачем? Остаётся много вопросов. Этот раздел добавляет ещё один кусок пазла.

При каждой composition (или recomposition) выполняются Composable-функции и **эмитируют**. «Эмитирование» мы уже много раз использовали. Эмитирование — создание **отложенных изменений** для обновления slot table и в итоге материализованного дерева. Эти изменения хранятся в списке. Новый список строится на основе того, что уже есть в slot table: любые изменения дерева зависят от текущего состояния Composition.

Пример — перемещение узла. При переупорядочивании Composable в списке нужно найти старую позицию узла в таблице, удалить его слоты и записать их заново с новой позиции.

То есть при каждом эмитировании Composable смотрит в slot table, создаёт отложенное изменение по потребности и текущим данным и добавляет его в список. Позже, по завершении composition, наступает материализация и **записанные** изменения выполняются — обновляют slot table актуальной информацией Composition. Поэтому эмитирование быстро: создаётся отложенное действие, которое будет выполнено позже.

Список изменений в итоге и вносит изменения в таблицу. Сразу после этого он уведомляет Applier об обновлении материализованного дерева узлов.

Как сказано выше, `Recomposer` оркестрирует процесс: на каком потоке выполнять composition/recomposition и на каком применять изменения. Последний контекст также используется по умолчанию для запуска эффектов в `LaunchedEffect`.

Теперь яснее, как изменения записываются, откладываются и выполняются и как состояние хранится в slot table. Пора разобрать `Composer`.

## Composer

Внедрённый `$composer` связывает написанные нами Composable-функции с Compose runtime.

## Подача данных в Composer

Разберём, как узлы добавляются в in-memory представление дерева. Возьмём Composable `Layout`. `Layout` — основа всех UI-компонентов Compose UI. В коде это выглядит так:

```kotlin
 1 @Suppress(&quot;ComposableLambdaParameterPosition&quot;)
 2 @Composable inline fun Layout(
 3   content: @Composable () -&gt; Unit,
 4   modifier: Modifier = Modifier,
 5   measurePolicy: MeasurePolicy
 6 ) {
 7   val density = LocalDensity.current
 8   val layoutDirection = LocalLayoutDirection.current
 9   ReusableComposeNode&lt;ComposeUiNode, Applier&lt;Any&gt;&gt;(
10     factory = ComposeUiNode.Constructor,
11       update = {
12         set(measurePolicy, ComposeUiNode.SetMeasurePolicy)
13         set(density, ComposeUiNode.SetDensity)
14         set(layoutDirection, ComposeUiNode.SetLayoutDirection)
15       },
16       skippableUpdate = materializerOf(modifier),
17       content = content
18   )
19 }
```
*Layout.kt*

`Layout` использует `ReusableComposeNode`, чтобы эмитировать `LayoutNode` в composition. Звучит как «создать и сразу добавить узел», но на деле это **обучение рантайма** тому, как создать, инициализировать и вставить узел в текущую позицию Composition **когда придёт время**. Код:

```kotlin
 1 @Composable
 2 inline fun &lt;T, reified E : Applier&lt;*&gt;&gt; ReusableComposeNode(
 3   noinline factory: () -&gt; T,
 4   update: @DisallowComposableCalls Updater&lt;T&gt;.() -&gt; Unit,
 5   noinline skippableUpdate: @Composable SkippableUpdater&lt;T&gt;.() -&gt; Unit,
 6   content: @Composable () -&gt; Unit
 7 ) {
 8   // ...
 9   currentComposer.startReusableNode()
10   // ...
11   currentComposer.createNode(factory)
12   // ...
13   Updater&lt;T&gt;(currentComposer).update() // initialization
14   // ...
15   currentComposer.startReplaceableGroup(0x7ab4aae9)
16   content()
17   currentComposer.endReplaceableGroup()
18   currentComposer.endNode()
19 }
```
*ReusableComposeNode.kt*

Часть несущественного опущена; всё делегируется экземпляру `currentComposer`. Видно также использование replaceable group для оборачивания content при хранении. Всё, что эмитируется внутри лямбды `content`, будет храниться как дети этой группы (и значит этого Composable) в Composition.

Та же операция эмитирования выполняется для любых других Composable. Например, `remember`:

```kotlin
1 @Composable
2 inline fun &lt;T&gt; remember(calculation: @DisallowComposableCalls () -&gt; T): T =
3   currentComposer.cache(invalid = false, calculation)
```
*Composables.kt*

Composable `remember` использует `currentComposer`, чтобы закэшировать (запомнить) значение лямбды в composition. Параметр `invalid` принудительно обновляет значение даже если оно уже сохранено. Функция `cache` реализована так:

```kotlin
 1 @ComposeCompilerApi
 2 inline fun &lt;T&gt; Composer.cache(invalid: Boolean, block: () -&gt; T): T {
 3   return rememberedValue().let {
 4     if (invalid || it === Composer.Empty) {
 5       val value = block()
 6       updateRememberedValue(value)
 7       value
 8     } else it
 9   } as T
10 }
```
*Composer.kt*

Сначала ищется значение в Composition (slot table). Если не найдено — эмитируются изменения для **запланированного обновления** значения (то есть запись). Иначе возвращается сохранённое значение.

## Моделирование изменений

Как в предыдущем разделе, все операции эмитирования, делегированные `currentComposer`, внутри представлены как `Change`, добавляемые в список. `Change` — отложенная функция с доступом к текущему `Applier` и `SlotWriter` (напоминание: активный writer в каждый момент один). В коде:

```kotlin
1 internal typealias Change = (
2   applier: Applier&lt;*&gt;,
3   slots: SlotWriter,
4   rememberManager: RememberManager
5 ) -&gt; Unit
```
*Composer.kt*

Эти изменения добавляются в список (записываются). «Эмитирование» по сути — создание таких `Change`, отложенных лямбд для добавления, удаления, замены или перемещения узлов в slot table и уведомления `Applier` (чтобы изменения материализовались).

Поэтому «эмитирование изменений» можно называть «записью» или «планированием» изменений — речь об одном и том же.

После composition, когда все вызовы Composable завершены и изменения записаны, **все они применяются пакетно через Applier**.

Сама composition моделируется классом `Composition`. Пока отложим его — процесс composition разберём ниже. Сначала ещё несколько деталей о Composer.

## Оптимизация момента записи

Как мы видели, вставка новых узлов делегируется Composer — он всегда знает, когда уже идёт процесс **вставки** узлов в composition. В этом случае Composer может не откладывать запись и сразу писать в slot table при эмитировании изменений вместо их записи в список. В остальных случаях изменения записываются и откладываются — время ещё не пришло.

## Запись и чтение групп

По завершении composition вызывается `composition.applyChanges()` для материализации дерева, и изменения записываются в slot table. Composer может записывать разные типы информации: данные, узлы, группы. Всё в итоге хранится в виде групп с разными полями для различения.

Composer может «начать» и «закончить» любую группу. Смысл зависит от действия: при записи это «группа создана» / «группа удалена» в slot table; при чтении `SlotReader` перемещает указатели чтения внутрь и наружу группы.

Узлы в дереве Composable (в таблице — группы) не только вставляются, но могут удаляться или перемещаться. Удаление группы — удаление её и всех её слотов из таблицы. Composer перепозиционирует `SlotReader`, заставляет его пропустить группу (её уже нет) и записывает операции удаления узлов в Applier. Все модификации планируются (записываются) и применяются пакетно позже — чтобы они были согласованы. Composer также отменяет все отложенные инвалидации удалённой группы.

Не все группы restartable, replaceable, movable или reusable. Среди прочего группами хранятся, например, блоки-обёртки для значений по умолчанию — они окружают запомненные значения для вызовов Composable с параметрами по умолчанию, например `model: Model = remember { DefaultModel() }`.

Когда Composer хочет начать группу:

- Если Composer в режиме **вставки**, он сразу пишет в slot table.
- Иначе при наличии отложенных операций записывает изменения для применения. Composer попытается переиспользовать группу, если она уже есть в таблице.
- Если группа уже сохранена **в другой позиции** (перемещена), записывается операция перемещения всех слотов группы.
- Если группа новая (не найдена в таблице), включается режим `inserting`: группа и все её дети записываются в промежуточную `insertTable` (другой SlotTable) до завершения группы, затем планируется вставка групп в итоговую таблицу.
- Если Composer не в режиме вставки и нет отложенных операций записи, он пытается начать чтение группы.

Переиспользование групп часто: иногда новый узел не нужен, можно использовать существующий (см. `ReusableComposeNode` выше). Эмитируется (записывается) операция перехода к узлу через Applier, но пропускаются операции создания и инициализации.

Когда нужно обновить свойство узла, это действие тоже записывается как `Change`.

## Запоминание значений

Composer умеет **запоминать** значения в Composition (писать их в slot table) и позже обновлять. Сравнение с прошлой composition выполняется при вызове `remember`, но действие обновления записывается как `Change`, если Composer не в режиме вставки.

Когда запоминаемое значение — `RememberObserver`, Composer также записывает неявный `Change` для отслеживания запоминания в Composition — это понадобится при «забывании» запомненных значений.

## Recompose scope

Через Composer создаются и recompose scope, обеспечивающие умную recomposition. Они связаны с restart-группами. При создании restart group Composer создаёт для неё `RecomposeScope` и устанавливает его как `currentRecomposeScope` для Composition.

`RecomposeScope` — область Composition, которую можно перезапускать независимо от остального. Её можно вручную инвалидировать для запуска recomposition Composable: `composer.currentRecomposeScope().invalidate()`. При recomposition Composer позиционирует slot table на начало этой группы и вызывает переданную лямбду recompose — по сути снова вызывается Composable, он эмитирует ещё раз, и Composer перезаписывает его данные в таблице.

Composer ведёт `Stack` всех инвалидированных recompose scope — то есть ожидающих recomposition. `currentRecomposeScope` получается через peek в этот стек.

`RecomposeScope` не всегда активны — только когда Compose находит чтение из snapshot `State` внутри Composable. Тогда Composer помечает `RecomposeScope` как `used`, и вставленный вызов «end» в конце Composable **перестаёт возвращать null** — активируется следующая за ним лямбда recomposition (после `?`):

```kotlin
 1 // After compiler inserts boilerplate
 2 @Composable
 3 fun A(x: Int, $composer: Composer&lt;*&gt;, $changed: Int) {
 4   $composer.startRestartGroup()
 5   // ...
 6   f(x)
 7   $composer.endRestartGroup()?.updateScope { next -&gt; 
 8     A(x, next, $changed or 0b1) 
 9   }
10 }
```
*RecomposeScope.kt*

Composer может перезапустить все инвалидированные дочерние группы текущего родителя при необходимости или просто заставить reader пропустить группу до конца (см. раздел о comparison propagation в главе 2).

## SideEffect в Composer

Composer также записывает `SideEffect`. `SideEffect` всегда выполняется **после composition**. Они записываются как функции для вызова, когда изменения соответствующего дерева **уже применены**. Это эффекты «сбоку», не привязанные к жизненному циклу Composable — не будет автоматической отмены при выходе из Composition и повторного запуска при recomposition. Такой эффект **не хранится в slot table** и при падении composition просто отбрасывается. Подробнее — в главе про обработчики эффектов; здесь важно, что они записываются через Composer.

## Хранение CompositionLocal

Composer даёт возможность регистрировать `CompositionLocal` и получать значения по ключу. Вызовы `CompositionLocal.current` опираются на это. Provider и его значения тоже хранятся группой в slot table.

## Хранение информации об исходниках

Composer сохраняет информацию об исходниках в виде `CompositionData`, собранной во время composition, для инструментов Compose.

## Связывание Composition через CompositionContext

Composition не одна — есть дерево composition и subcomposition. Subcomposition — Composition, создаваемая inline в контексте текущей для независимой инвалидации.

Subcomposition связана с родительской Composition ссылкой на родительский `CompositionContext`. Контекст связывает composition и subcomposition в дерево и обеспечивает прозрачное разрешение/распространение `CompositionLocal` и инвалидаций вниз по дереву, как будто это одна Composition. Сам `CompositionContext` тоже записывается в slot table как группа.

Subcomposition обычно создаётся через `rememberCompositionContext`:

```kotlin
1 @Composable fun rememberCompositionContext(): CompositionContext {
2   return currentComposer.buildContext()
3 }
```
*Composables.kt*

Функция запоминает новую Composition в текущей позиции в slot table или возвращает уже запомненную. Используется для создания Subcomposition там, где нужна отдельная Composition: `VectorPainter`, `Dialog`, `SubcomposeLayout`, `Popup`, `AndroidView` (обёртка для интеграции Android View в composable-деревья).

## Доступ к текущему State snapshot

Composer хранит ссылку на текущий snapshot — снимок значений mutable state и других state-объектов для текущего потока. В snapshot все state-объекты имеют те же значения, что в момент создания snapshot, пока их явно не изменят в нём. Подробнее — в главе об управлении состоянием.

## Навигация по узлам

Навигация по дереву узлов выполняется Applier не напрямую: при обходе reader записываются все позиции узлов в массив `downNodes`, и при материализации навигации все «down» проигрываются в Applier. Если «up» записан до соответствующего «down», он просто убирается из стека downNodes как сокращение.

## Синхронизация reader и writer

На низком уровне: так как группы могут вставляться, удаляться или перемещаться, позиция группы у writer может какое-то время отличаться от позиции у reader (пока изменения не применены). Поэтому ведётся delta для учёта разницы; она обновляется при вставках, удалениях и перемещениях и отражает «нереализованное расстояние, на которое writer должен сдвинуться, чтобы совпасть с текущим слотом в reader» (по документации).

## Применение изменений

Как мы многократно говорили, за это отвечает `Applier`. Текущий `Composer` делегирует этой абстракции применение всех записанных изменений после composition — это и есть «материализация». Процесс выполняет список Change, в результате обновляется slot table и интерпретируются данные Composition для получения результата.

**Рантайм не зависит от реализации `Applier`**. Он опирается на публичный контракт, который должны реализовать клиентские библиотеки. Applier — точка интеграции с платформой и зависит от сценария. Контракт:

```kotlin
 1 interface Applier&lt;N&gt; {
 2   val current: N
 3   fun onBeginChanges() {}
 4   fun onEndChanges() {}
 5   fun down(node: N)
 6   fun up()
 7   fun insertTopDown(index: Int, instance: N)
 8   fun insertBottomUp(index: Int, instance: N)
 9   fun remove(index: Int, count: Int)
10   fun move(from: Int, to: Int, count: Int)
11   fun clear()
12 }
```
*Applier.kt*

Параметр типа `N` в контракте — тип узлов, к которым применяются изменения. Поэтому Compose может работать с произвольными графами вызовов и деревьями узлов. Есть операции обхода дерева, вставки, удаления и перемещения узлов; тип узлов и способ их вставки не заданы. Спойлер: **это делегируется самим узлам**.

Контракт также задаёт удаление дочерних узлов в диапазоне и перемещение дочерних узлов. Операция `clear` сбрасывает состояние к корню и удаляет все узлы, подготавливая Applier и корень к новой composition.

Applier обходит всё дерево и применяет изменения. Обход может быть сверху вниз или снизу вверх. Хранится ссылка на текущий посещаемый узел. Есть вызовы начала/окончания применения изменений (Composer вызывает их до и после) и средства вставки top-down или bottom-up и навигации вниз (к дочернему) или вверх (к родителю).

## Производительность при построении дерева узлов

Важное различие — строить дерево сверху вниз или снизу вверх. Пример из официальной документации.

### Вставка top-down

Дерево:

![](resources/tree1.png)
*tree1*

При построении сверху вниз: вставить `B` в `R`, затем `A` в `B`, затем `C` в `B`:

![](resources/tree2.png)
*tree2*

### Вставка bottom-up

Снизу вверх: сначала вставить `A` и `C` в `B`, затем дерево `B` в `R`.

![](resources/tree3.png)
*tree3*

Производительность top-down и bottom-up может сильно различаться. Выбор за реализацией Applier и часто зависит от числа узлов, которых нужно уведомить при вставке каждого ребёнка. Если при вставке узла нужно уведомлять всех предков, при top-down каждая вставка может уведомлять много узлов (родитель, родитель родителя…), и число растёт экспоненциально. При bottom-up уведомляется только непосредственный родитель, так как он ещё не присоединён к дереву. Если стратегия — уведомлять детей, может быть наоборот. Итог: выбор стратегии вставки зависит от дерева и того, как нужно распространять уведомления; важно выбрать одну стратегию и не смешивать.

## Как применяются изменения

Клиентские библиотеки реализуют интерфейс `Applier`; для Android UI пример — `UiApplier`. По нему видно, что значит «применить узел» и как получаются видимые на экране компоненты.

Реализация узкая:

```kotlin
 1 internal class UiApplier(
 2     root: LayoutNode
 3 ) : AbstractApplier&lt;LayoutNode&gt;(root) {
 4 
 5   override fun insertTopDown(index: Int, instance: LayoutNode) {
 6     // Ignored.
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
 24 
25   override fun onEndChanges() {
26     super.onEndChanges()
27     (root.owner as? AndroidComposeView)?.clearInvalidObservations()
28   }
29 }
```
*UiApplier.kt*

Параметр типа `N` зафиксирован как `LayoutNode` — тип узла Compose UI для отображаемых UI-узлов.

Видно наследование от `AbstractApplier` — дефолтная реализация хранит посещённые узлы в `Stack`: при спуске узел добавляется, при подъёме снимается с вершины. Это типично для applier, поэтому вынесено в общий базовый класс.

`insertTopDown` в `UiApplier` игнорируется — вставки выполняются снизу вверх на Android. Как сказано, важно выбрать одну стратегию. Снизу вверх здесь уместнее, чтобы избежать дублирующих уведомлений при вставке ребёнка.

Методы вставки, удаления и перемещения **делегируются самому узлу**. `LayoutNode` — модель UI-узла в Compose UI, он знает о родителе и детях. Вставка — присоединение к новому родителю в заданную позицию. Перемещение — переупорядочивание списка детей родителя. Удаление — удаление из списка.

По завершении применения изменений вызывается `onEndChanges()` (перед применением предполагается вызов `onBeginChanges()`). На корневом узле owner выполняется финальное действие — очистка отложенных invalid observations. Это наблюдения за snapshot для автоматического перезапуска layout или draw при изменении зависимых значений (например, при добавлении, вставке, замене или перемещении узлов).

## Присоединение и отрисовка узлов

Как вставка узла в дерево (присоединение к родителю) в итоге приводит к отображению на экране? **Узел сам умеет присоединяться и отрисовываться.**

Кратко: полный разбор в главе 4 (Compose UI). Этого достаточно, чтобы замкнуть картину.

`LayoutNode` — тип узла для Android UI. При делегировании вставки ему в `UiApplier` происходит следующее:

- Проверка условий вставки (например, у узла ещё нет родителя).
- Инвалидация списка детей, отсортированных по Z-index (параллельный список для порядка отрисовки). Инвалидация заставляет список пересоздаваться при следующем обращении.
- Присоединение узла к родителю и к его `Owner` (см. ниже).
- Вызов invalidate.

Owner находится в корне дерева и реализует **связь composable-дерева с системой View**. Это тонкий слой интеграции с Android; реализация — `AndroidComposeView` (обычный `View`). Layout, draw, ввод и доступность завязаны на owner. `LayoutNode` должен быть присоединён к `Owner`, чтобы отображаться; owner должен совпадать с owner родителя. Owner — часть Compose UI. После присоединения можно вызвать `invalidate` через Owner для отрисовки дерева.

![](resources/layoutnode_tree.png)
*Иерархия LayoutNode*

Точка интеграции — установка Owner при вызове `setContent` из Activity, Fragment или ComposeView. Создаётся `AndroidComposeView`, присоединяется к иерархии View и устанавливается как Owner для вызова invalidate по требованию.

Итог: мы проследили, как Compose UI материализует дерево узлов для Android. Подробнее — в следующей главе.

Цикл замкнут, но мы пока не разобрали сам процесс composition. Пора к нему.

## Composition

Мы много узнали о Composer: как он записывает изменения для slot table, как изменения эмитируются при выполнении Composable во время composition и как записанные изменения применяются в конце. Но мы ещё не сказали, кто создаёт Composition, как и когда это происходит и какие шаги задействованы. Composition — недостающий кусок.

Мы говорили, что у Composer есть ссылка на Composition; может показаться, что Composition создаётся и принадлежит Composer. На деле наоборот: при создании Composition он сам создаёт Composer. Composer доступен через механизм `currentComposer` и используется для создания и обновления дерева, которым управляет Composition.

Точка входа в Jetpack Compose runtime для клиентских библиотек состоит **из двух частей**:

- Написание Composable-функций — они эмитируют нужную информацию и связывают сценарий с рантаймом.
- Composable-функции не выполнятся без процесса composition. Нужна вторая точка входа — `setContent`. Это слой интеграции с платформой; здесь создаётся и запускается `Composition`.

## Создание Composition

На Android это может быть вызов `ViewGroup.setContent`, возвращающий новый `Composition`:

```kotlin
 1 internal fun ViewGroup.setContent(
 2   parent: CompositionContext,
 3   content: @Composable () -&gt; Unit
 4 ): Composition {
 5   // ...
 6   val composeView = ...
 7   return doSetContent(composeView, parent, content)
 8 }
 9 
10 private fun doSetContent(
11   owner: AndroidComposeView,
12   parent: CompositionContext,
13   content: @Composable () -&gt; Unit
14 ): Composition {
15   // ...
16   val original = Composition(UiApplier(owner.root), parent) // Here!
17   val wrapped = owner.view.getTag(R.id.wrapped_composition_tag)
18     as? WrappedComposition ?: WrappedComposition(owner, original).also {
19       owner.view.setTag(R.id.wrapped_composition_tag, it)
20     }
21   wrapped.setContent(content)
22   return wrapped
23 }
```
*Wrapper.android.kt*

`WrappedComposition` — декоратор, связывающий `Composition` с `AndroidComposeView` и с системой View Android. Он запускает контролируемые эффекты (например, видимость клавиатуры, доступность) и передаёт информацию об Android `Context` в Composition как `CompositionLocal` (контекст, конфигурация, текущий LifecycleOwner, savedStateRegistryOwner, view owner и т.д.). Так всё это становится неявно доступным в Composable-функциях.

В Composition передаётся экземпляр `UiApplier`, изначально указывающий на корневой `LayoutNode` (Applier — посетитель узлов, стартует с корня). Явно видно, что реализацию `Applier` выбирает клиентская библиотека.

В конце вызывается `composition.setContent(content)`. `Composition#setContent` задаёт содержимое Composition.

Другой пример — `VectorPainter` в Compose UI для отрисовки векторов. Vector painter создаёт и хранит свой `Composition`:

```kotlin
 1 @Composable
 2 internal fun RenderVector(
 3   name: String,
 4   viewportWidth: Float,
 5   viewportHeight: Float,
 6   content: @Composable (viewportWidth: Float, viewportHeight: Float) -&gt; Unit
 7 ) {
 8   // ...
 9   val composition = composeVector(rememberCompositionContext(), content)
10 
11   DisposableEffect(composition) {
12     onDispose {
13       composition.dispose() // composition needs to be disposed in the end!
14     }
15   }
16 }
17 
18 private fun composeVector(
19   parent: CompositionContext,
20   composable: @Composable (viewportWidth: Float, viewportHeight: Float) -&gt; Unit
21 ): Composition {
22   val existing = composition
23   val next = if (existing == null || existing.isDisposed) {
24     Composition(VectorApplier(vector.root), parent) // Here!
25   } else {
26     existing
27   }
28   composition = next
29   next.setContent {
30     composable(vector.viewportWidth, vector.viewportHeight)
31   }
32   return next
33 }
```
*VectorPainter.kt*

Другой выбор Applier — `VectorApplier` с корневым узлом дерева векторов (`VNode`). Подробнее — в главе о продвинутых сценариях Compose.

Ещё пример — `SubcomposeLayout` в Compose UI: Layout со своей Composition для subcompose контента во время фазы измерения (когда размер родителя нужен для composition детей).

При создании Composition можно передать родительский `CompositionContext` (он может быть `null`). Родительский контекст связывает новую composition с существующей логически, чтобы инвалидации и `CompositionLocal` разрешались через composition, как будто это одна. При создании можно также передать recompose context — `CoroutineContext` для Applier при применении изменений; по умолчанию от Recomposer (`EmptyCoroutineContext`), на Android обычно `AndroidUiDispatcher.Main`.

Composition нужно освобождать — `composition.dispose()`, когда он больше не нужен. Иногда освобождение скрыто (например, за lifecycle observer в `ViewGroup.setContent`), но оно всегда есть. Composition привязан к своему owner.

## Процесс первичной composition

После создания Composition следует вызов `composition.setContent(content)` (см. фрагменты выше). Им изначально заполняется Composition (slot table).

Вызов делегируется **родительской** Composition для запуска первичной composition (Composition и Subcomposition связаны через родительский `CompositionContext`):

```kotlin
1 override fun setContent(content: @Composable () -&gt; Unit) {
2   // ...
3   this.composable = content
4   parent.composeInitial(this, composable) // `this` is the current Composition
5 }
```
*Composition.kt*

Для Subcomposition родитель — другая Composition; для корневой — `Recomposer`. В любом случае логика первичной composition в итоге опирается на Recomposer: у Subcomposition вызов `composeInitial` делегируется родителю до корневой Composition.

Вызов `parent.composeInitial(composition, content)` сводится к `recomposer.composeInitial(composition, content)`. Recomposer делает следующее для заполнения первичной Composition:

- Берётся **snapshot** текущих значений всех State. Значения изолируются от изменений в других snapshot. Snapshot **мутабелен** и потокобезопасен: изменения State внутри него не затрагивают другие snapshot; позже все изменения атомарно синхронизируются с глобальным состоянием.
- Значения State в этом snapshot можно менять только внутри блока при вызове `snapshot.enter(block: () -> T)`.
- При создании snapshot Recomposer передаёт наблюдателей за чтениями и записями этих State, чтобы Composition получал уведомления и помечал затронутые recompose scope как `used` для последующей recomposition.
- Выполняется вход в snapshot — `snapshot.enter(block)` с блоком `composition.composeContent(content)`. **Здесь и происходит composition**. Вход в snapshot даёт Recomposer отслеживать чтения и записи State во время composition.
- Процесс composition делегируется Composer (подробнее ниже).
- После composition все изменения State остаются в текущем snapshot; их нужно распространить в глобальное состояние через `snapshot.apply()`.

Примерный порядок первичной composition. Система State snapshot подробнее — в следующей главе.

Сам процесс composition, делегированный Composer, в общих чертах:

- Composition не может начаться, если уже идёт — выбрасывается исключение, новая Composition отбрасывается. Повторный вход не поддерживается.
- При наличии отложенных инвалидаций они копируются в список инвалидаций Composer для RecomposeScope.
- Устанавливается флаг `isComposing = true`.
- Вызывается `startRoot()` — начало корневой группы в slot table и инициализация структур.
- `startGroup` для группы `content` в slot table.
- Вызов лямбды `content` — эмитирование изменений.
- `endGroup` — конец группы.
- `endRoot()` — конец composition.
- `isComposing = false`.
- Очистка временных структур.

## Применение изменений после первичной composition

После первичной composition Applier уведомляется о применении записанных изменений: `composition.applyChanges()`. Composition вызывает `applier.onBeginChanges()`, выполняет все изменения из списка, передавая им Applier и SlotWriter, затем `applier.onEndChanges()`.

После этого диспатчатся все зарегистрированные `RememberedObserver` — классы, реализующие `RememberObserver`, уведомляются о входе и выходе из Composition. Так работают `LaunchedEffect`, `DisposableEffect` и др. — привязка эффекта к жизненному циклу Composable в Composition.

Затем в порядке записи вызываются все `SideEffect`.

## Дополнительно о Composition

Composition знает об отложенных инвалидациях для recomposition и о том, идёт ли сейчас composition. Это используется для немедленного применения инвалидаций (если composition идёт) или откладывания; Recomposer может отменять recomposition, когда composition активна.

Рантайм использует вариант Composition — `ControlledComposition` с дополнительными методами внешнего управления. Recomposer может оркестрировать инвалидации и recomposition через функции вроде `composeContent` или `recompose`.

Composition позволяет проверить, наблюдает ли он за набором объектов, чтобы запускать recomposition при их изменении. Например, Recomposer запускает recomposition дочерней composition при изменении `CompositionLocal` в родительской (composition связаны через родительский CompositionContext).

При ошибке во время composition процесс может быть прерван — по сути сброс Composer и всех ссылок/стеков.

Composer считает, что выполняется пропуск recomposition, когда не идёт вставка и не переиспользование, нет инвалидированных provider и текущий `RecomposeScope` не требует recomposition. Умная recomposition разбирается в отдельной главе.

## Recomposer

Мы знаем, как происходит первичная composition и что такое RecomposeScope и инвалидация. Но как именно работает Recomposer? Как и когда он создаётся и начинает слушать инвалидации для автоматической recomposition?

Recomposer управляет `ControlledComposition` и запускает recomposition при необходимости для применения обновлений. Он также решает, на каком потоке выполнять composition/recomposition и применять изменения.

## Запуск Recomposer

Точка входа в Jetpack Compose для клиентских библиотек — создание Composition и вызов `setContent` (раздел **Создание Composition**). При создании Composition нужно передать родителя. Для корневой Composition родитель — `Recomposer`, поэтому его создают в тот же момент.

Эта точка входа — связь платформы с Compose runtime; код поставляет клиент. На Android — Compose UI: создаётся Composition (внутри — свой Composer) и Recomposer как родитель.

У каждого сценария на платформе может быть своя Composition и свой Recomposer.

На Android при вызове `ViewGroup.setContent` после нескольких уровней создание родительского контекста делегируется фабрике Recomposer:

```kotlin
 1 fun interface WindowRecomposerFactory {
 3   fun createRecomposer(windowRootView: View): Recomposer
 5   companion object {
 6     val LifecycleAware: WindowRecomposerFactory = WindowRecomposerFactory { rootView\
 7  -&gt;
 8       rootView.createLifecycleAwareViewTreeRecomposer()
 9     }
10   }
11 }
```

Фабрика создаёт Recomposer для текущего окна. Корневой view нужен, чтобы Recomposer был **lifecycle-aware** — привязан к `ViewTreeLifecycleOwner` и мог останавливаться при откреплении дерева View (важно для отсутствия утечек; процесс моделируется приостанавливаемой функцией).

Важно: в Compose UI всё на UI координируется через `AndroidUiDispatcher`, связанный с `Choreographer` и handler основного `Looper`. Диспетчер выполняет обработку в callback handler или на этапе кадра анимации Choreographer — **что наступит раньше**. У него есть связанный `MonotonicFrameClock` для координации кадров через `suspend` — основа UX в Compose, в том числе анимаций.

Фабрика сначала создаёт `PausableMonotonicFrameClock` — обёртку над монотонными часами `AndroidUiDispatcher` с возможностью приостанавливать диспетчеризацию `withFrameNanos` до возобновления. Нужно, когда кадры **не должны** производиться (например, окно не видно).

Любой `MonotonicFrameClock` — также `CoroutineContext.Element`. При создании Recomposer передаётся `CoroutineContext` — комбинация контекста текущего потока от `AndroidUiDispatcher` и только что созданного pausable clock:

```kotlin
1 val contextWithClock = currentThreadContext + (pausableClock ?: EmptyCoroutineContex\
2 t)
3 val recomposer = Recomposer(effectCoroutineContext = contextWithClock)
```
*WindowRecomposer.android*

Этот контекст используется Recomposer для внутренней `Job`, чтобы composition/recomposition эффекты можно было отменять при остановке Recomposer (например, при уничтожении или откреплении окна). **Этот контекст используется для применения изменений** после composition/recomposition и по умолчанию для запуска эффектов в `LaunchedEffect` (эффекты стартуют в том же потоке, что и применение изменений — на Android обычно main; внутри эффектов можно переключаться на другие потоки).

`LaunchedEffect` разбирается в соответствующей главе. Все обработчики эффектов — Composable и эмитируют изменения; `LaunchedEffect` записывается в slot table и привязан к жизненному циклу Composition, в отличие от `SideEffect`.

Создаётся scope корутин с тем же контекстом: `val runRecomposeScope = CoroutineScope(contextWithClock)`. В нём запускается job recomposition (suspend-функция), ожидающая инвалидаций и запускающая recomposition. Фрагмент кода:

```kotlin
 1 viewTreeLifecycleOwner.lifecycle.addObserver(
 2   object : LifecycleEventObserver {
 3     override fun onStateChanged(lifecycleOwner: LifecycleOwner, event: Lifecycle.Eve\
 4 nt) {
 5       val self = this
 7       when (event) {
 8         Lifecycle.Event.ON_CREATE -&gt;
 9           runRecomposeScope.launch(start = CoroutineStart.UNDISPATCHED) {
10           try {
11             recomposer.runRecomposeAndApplyChanges()
12           } finally {
13             // After completion or cancellation
14             lifecycleOwner.lifecycle.removeObserver(self)
15           }
16         }
17         Lifecycle.Event.ON_START -&gt; pausableClock?.resume()
18         Lifecycle.Event.ON_STOP -&gt; pausableClock?.pause()
19         Lifecycle.Event.ON_DESTROY -&gt; {
20           recomposer.cancel()
21         }
22       }
23     }
24   }
25 )
```
*WindowRecomposer.android.kt*

Наблюдатель подписывается на lifecycle дерева View: при ON_START возобновляет pausable clock, при ON_STOP приостанавливает, при ON_DESTROY отменяет Recomposer, при ON_CREATE запускает job recomposition.

Job запускается вызовом `recomposer.runRecomposeAndApplyChanges()` — приостанавливаемая функция, ожидающая инвалидации связанных Composer (и их RecomposeScope), выполняющая recomposition и применение изменений к соответствующим Composition.

Так Compose UI запускает Recomposer, привязанный к жизненному циклу Android. Напоминание — создание composition при установке контента для ViewGroup:

```kotlin
 1 internal fun ViewGroup.setContent(
 2   parent: CompositionContext, // Recomposer is passed here!
 3   content: @Composable () -&gt; Unit
 4 ): Composition {
 5   // ...
 6   val composeView = ...
 7   return doSetContent(composeView, parent, content)
 8 }
 9 
10 private fun doSetContent(
11   owner: AndroidComposeView,
12   parent: CompositionContext,
13   content: @Composable () -&gt; Unit
14 ): Composition {
15   // ...
16   val original = Composition(UiApplier(owner.root), parent) // Here!
17   val wrapped = owner.view.getTag(R.id.wrapped_composition_tag)
18     as? WrappedComposition ?: WrappedComposition(owner, original).also {
19       owner.view.setTag(R.id.wrapped_composition_tag, it)
20     }
21   wrapped.setContent(content)
22   return wrapped
23 }
```
*Wrapper.android.kt*

Параметр `parent` здесь — Recomposer; его передаёт вызывающий `setContent` (для этого сценария — `AbstractComposeView`).

## Процесс recomposition

Функция `recomposer.runRecomposeAndApplyChanges()` запускает ожидание инвалидаций и автоматическую recomposition. Кратко шаги:

Ранее мы видели, что изменения State snapshot применяются в своём snapshot, затем распространяются в глобальное состояние через `snapshot.apply()`. При вызове `recomposer.runRecomposeAndApplyChanges()` первым делом регистрируется наблюдатель за этим распространением. При распространении наблюдатель просыпается и добавляет изменения в список инвалидаций snapshot, которые передаются всем известным Composer для записи частей composition, требующих recomposition. Проще: этот наблюдатель — ступенька для автоматической recomposition при изменении State.

После регистрации наблюдателя Recomposer инвалидирует все Composition, полагая, что всё изменилось — старт с чистого листа. Затем приостанавливается до появления работы для recomposition. «Работа» — отложенные инвалидации State snapshot или инвалидации composition от RecomposeScope.

Далее Recomposer использует переданный при создании монотонный clock и вызывает `parentFrameClock.withFrameNanos {}`, ожидая следующий кадр. Остальная работа выполняется в этот момент — объединение изменений к кадру.

Внутри блока сначала диспатчатся кадры монотонного clock для ожидающих (например, анимаций); это может породить новые инвалидации.

Затем Recomposer берёт все отложенные инвалидации snapshot (изменённые с прошлого вызова recompose значения State) и записывает их в composer как отложенные recomposition.

Могут быть инвалидированные Composition (через `composition.invalidate()`), например при записи State в лямбде Composable. Для каждой выполняется recomposition (см. ниже) и Composition добавляется в список с отложенными изменениями.

Recomposition — пересчёт всех нужных `Change` для состояния Composition (slot table) и материализованного дерева (Applier), как мы уже разбирали. Код тот же, что и для первичной composition.

Затем находятся возможные «хвостовые» recomposition из-за изменений в другой composition (например, изменение `CompositionLocal` в родителе, прочитанного в дочерней composition) и тоже планируются.

Наконец, по всем Composition с отложенными изменениями вызывается `composition.applyChanges()`, после чего обновляется состояние Recomposer.

## Параллельная recomposition

Recomposer может выполнять recomposition параллельно, хотя Compose UI этим не пользуется. Другие клиентские библиотеки могут опираться на это.

У Recomposer есть вариант `runRecomposeAndApplyChanges` — `runRecomposeConcurrentlyAndApplyChanges`. Это тоже приостанавливаемая функция ожидания инвалидаций State и автоматической recomposition, но recomposition инвалидированных Composition выполняется в переданном извне `CoroutineContext`:

```kotlin
1 suspend fun runRecomposeConcurrentlyAndApplyChanges(
2   recomposeCoroutineContext: CoroutineContext
3 ) { /* ... */ }
```
*Recomposer.kt*

Функция создаёт свой `CoroutineScope` с переданным контекстом и использует его для запуска и координации дочерних job параллельных recomposition.

## Состояния Recomposer

В течение жизни Recomposer переключается между состояниями:

```kotlin
1 enum class State {
2   ShutDown,
3   ShuttingDown,
4   Inactive,
5   InactivePendingWork,
6   Idle,
7   PendingWork
8 }
```
*Recomposer.kt*

По kdoc, значения состояний:

- `ShutDown`: Recomposer отменён, очистка завершена. Использовать нельзя.
- `ShuttingDown`: Recomposer отменён, очистка в процессе. Использовать нельзя.
- `Inactive`: Recomposer игнорирует инвалидации от Composer и не запускает recomposition. Нужно вызвать `runRecomposeAndApplyChanges` для начала прослушивания. Начальное состояние после создания.
- `InactivePendingWork`: Recomposer неактивен, но уже есть отложенные эффекты, ожидающие кадра; кадр будет произведён при запуске.
- `Idle`: Recomposer отслеживает инвалидации composition и snapshot, работы сейчас нет.
- `PendingWork`: Recomposer уведомлён об отложенной работе и выполняет её или ждёт возможности (что такое «отложенная работа», мы уже описали).
