# 5. Система state snapshot

У Jetpack Compose свой способ представлять состояние и распространять его изменения — система state snapshot, которая и даёт реактивность. Компоненты могут перезапускаться автоматически по своим входам и только когда нужно, без ручного уведомления об изменениях (как в старой системе View на Android).

Начнём с термина «snapshot state».

## Что такое snapshot state

Snapshot state — это **изолированное состояние, которое можно запомнить и наблюдать на предмет изменений**. Оно получается при вызове функций вроде `mutableStateOf`, `mutableStateListOf`, `mutableStateMapOf`, `derivedStateOf`, `produceState`, `collectAsState` и т.п. Все они возвращают какой-то тип `State`; разработчики называют это snapshot state.

Название связано с системой state snapshot в Jetpack Compose runtime: она задаёт модель и координацию изменений состояния и их распространения. Реализация вынесена в отдельный слой, так что теоретически ею могут пользоваться и другие библиотеки с наблюдаемым состоянием.

В главе 2 мы видели, что компилятор Compose оборачивает объявления и выражения Composable так, чтобы **автоматически отслеживать чтения snapshot state в их теле**. Так snapshot state наблюдается. Цель — при любом изменении прочитанного Composable состояния инвалидировать его `RecomposeScope` и выполнить его снова при следующей recomposition.

Это инфраструктурный код Compose; клиентскому коду он не нужен. Клиенты вроде Compose UI могут не знать, как делаются инвалидация, распространение состояния и запуск recomposition, и только поставлять строительные блоки — Composable-функции.

Snapshot state нужен не только для уведомления об изменениях и recomposition. Слово «snapshot» в названии важно из‑за **изоляции состояния** в контексте параллелизма.

Мутабельное состояние между потоками легко превращается в хаос: нужна жёсткая координация и синхронизация, иначе возможны коллизии, трудноуловимые баги и гонки. Языки решают это по-разному: неизменяемость данных, акторная модель с **изоляцией состояния** между потоками (у каждого актора своя копия, обмен через сообщения). Система snapshot в Compose не акторная, но к этому подходу близка.

Jetpack Compose опирается на мутабельное состояние, чтобы Composable автоматически реагировали на обновления. Только неизменяемое состояние не дало бы такой модели. Значит, нужно решать задачу общего состояния при параллельном выполнении (composition может идти в нескольких потоках, глава 1). Решение Compose — система state snapshot: изоляция состояния и последующее распространение изменений для **безопасной работы с мутабельным состоянием между потоками**.

Система snapshot state смоделирована как [система управления параллелизмом](https://en.wikipedia.org/wiki/Concurrency_control): нужно **согласовывать состояние между потоками**. Общее мутабельное состояние в параллельной среде — сложная и универсальная задача. Ниже мы разберём такие системы и их использование в Compose.

Полезно взглянуть на интерфейс `State`, который реализует любой snapshot state:

```kotlin
1 @Stable
2 interface State&lt;out T&gt; {
3   val value: T
4 }
```
*SnapshotState.kt*

Контракт помечен `@Stable`: Compose по замыслу даёт и использует только стабильные реализации. Напоминание: любая реализация **должна** обеспечивать согласованность `equals`, уведомление composition при изменении публичного свойства (`value`) и стабильность типов публичных свойств. В следующих разделах мы увидим, как при каждой записи (модификации) snapshot state object composition уведомляется.

Рекомендую [пост Зака Клиппа](https://dev.to/zachklipp/a-historical-introduction-to-the-compose-reactive-state-model-19j8) с введением в эти идеи.

## Системы управления параллелизмом

Система state snapshot реализована как система управления параллелизмом — начнём с этого понятия.

В информатике «управление параллелизмом» — обеспечение корректного результата при параллельных операциях, то есть координация и синхронизация. Оно задаётся набором правил для корректности системы в целом. Координация имеет цену и часто бьёт по производительности, поэтому важно проектировать подход по возможности эффективно.

Пример — транзакции в СУБД. Там управление параллелизмом гарантирует безопасное выполнение транзакций при параллельной работе без нарушения целостности. «Безопасность» включает атомарность, возможность отката, отсутствие потери зафиксированных эффектов и сохранение эффектов отменённых транзакций. В языках программирования похожие идеи используются, например, для транзакционной памяти — как раз случай системы state snapshot. Транзакционная память упрощает параллельное программирование, позволяя выполнять группу операций загрузки и сохранения атомарно. В Compose запись состояния применяется **одной атомарной операцией** при распространении изменений из snapshot в другие. Такая группировка упрощает согласование параллельных чтений и записей; атомарные изменения проще отменять, откатывать или воспроизводить.

Категории систем управления параллелизмом:

- **Оптимистичные:** не блокируют чтения и записи, предполагают безопасность, при нарушении правил при коммите отменяют транзакцию. Отменённая транзакция перезапускается (оверхед). Уместно, когда доля отменённых транзакций невелика.
- **Пессимистичные:** блокируют операцию транзакции при нарушении правил, пока возможность нарушения не исчезнет.
- **Полуоптимистичные:** гибрид — блокировка только в части случаев, в остальных оптимистичный подход с отменой при коммите.

Производительность зависит от пропускной способности, уровня параллелизма, риска взаимоблокировок. Неоптимистичные варианты сильнее склонны к дедлокам; часто решают отменой зависшей транзакции и перезапуском.

Jetpack Compose **оптимистичный**. Коллизии обновлений состояния обнаруживаются при распространении изменений (в конце), затем делается попытка автоматического слияния или отбрасывания (отмена изменений). Подробнее ниже.

Подход Compose проще, чем в СУБД: цель — только корректность. Свойства вроде восстанавливаемости, устойчивости, распределённости или репликации у Compose snapshot state нет (нет «D» в [ACID](https://en.wikipedia.org/wiki/ACID)). Snapshots Compose — только in-memory, в рамках процесса. Они атомарны, согласованы и изолированы.

Наряду с категориями (оптимистичная, пессимистичная, полуоптимистичная) есть типы; один из них — **многоверсионное управление параллелизмом (MVCC)**. Его использует Jetpack Compose. Система повышает параллелизм и производительность за счёт **создания новой версии объекта при каждой записи и возможности читать несколько последних релевантных версий**.

## Многоверсионное управление параллелизмом (MVCC)

Глобальное состояние Compose общее для всех Composition, то есть для **потоков**. Composable могут выполняться параллельно (дверь для параллельной recomposition открыта). При параллельном выполнении они могут читать и изменять snapshot state одновременно — нужна изоляция состояния.

Одно из ключевых свойств управления параллелизмом — **изоляция**: корректность при параллельном доступе к данным. Простейший способ — блокировать всех читателей до завершения писателей, но это плохо для производительности. MVCC (и Compose) делают иначе.

Для изоляции MVCC хранит **несколько копий** данных (snapshot), и каждый поток работает со своей изолированной копией состояния в данный момент — разными **версиями** состояния («многоверсионность»). Изменения потока не видны другим до завершения и распространения локальных изменений.

В теории управления параллелизмом это называется «snapshot isolation» — уровень изоляции, определяющий, какую версию видит каждая «транзакция» (snapshot).

MVCC опирается на неизменяемость: при записи создаётся новая копия данных. В памяти оказывается **несколько версий одних и тех же данных** — история изменений. В Compose это «state records»; мы к ним вернёмся.

Ещё одна особенность MVCC — **согласованные на момент времени представления** состояния (как у резервных копий). В MVCC это часто обеспечивается идентификатором транзакции. В Jetpack Compose так и есть: **каждому snapshot присваивается свой ID**. ID монотонно возрастают, snapshot упорядочены. Разные ID дают изоляцию чтений и записей без блокировок.

Рекомендую почитать про [Concurrency control](https://en.wikipedia.org/wiki/Concurrency_control) и [Multiversion concurrency control](https://en.wikipedia.org/wiki/Multiversion_concurrency_control).

## Snapshot

Snapshot можно взять в любой момент. Он отражает текущее состояние программы (все snapshot state объекты) в этот момент. Можно брать несколько snapshot; у каждого будет **своя изолированная копия состояния программы** — копия текущего состояния всех snapshot state объектов (реализующих `State`) в момент создания snapshot.

Так состояние безопасно менять: обновление в одном snapshot не затронет копии того же состояния в других. В многопоточном сценарии каждый поток может работать со своим snapshot и своей копией.

В Compose runtime класс `Snapshot` моделирует **текущее** состояние программы. Чтобы взять snapshot: `val snapshot = Snapshot.takeSnapshot()`. Будут зафиксированы текущие значения всех state объектов до вызова `snapshot.dispose()` — этим задаётся время жизни snapshot.

У snapshot есть жизненный цикл. После использования snapshot нужно освободить. Без вызова `snapshot.dispose()` утекут ресурсы и сохранённое состояние. Snapshot считается **активным** между созданием и освобождением.

При создании snapshot получает ID, чтобы его состояние можно было отличать от версий в других snapshot. Так состояние программы **версионируется** (многоверсионное управление параллелизмом).

Пример из [поста Зака Клиппа](https://dev.to/zachklipp/introduction-to-the-compose-snapshot-system-19cn):

```kotlin
 1 fun main() {
 2   val dog = Dog()
 3   dog.name.value = &quot;Spot&quot;
 4   val snapshot = Snapshot.takeSnapshot()
 5   dog.name.value = &quot;Fido&quot;
 6 
 7   println(dog.name.value)
 8   snapshot.enter { println(dog.name.value) }
 9   println(dog.name.value)
10 }
11 
12 // Output:
13 Fido
14 Spot
15 Fido
```
*SnapshotSample.kt*

Функция `enter` («вход в snapshot») **выполняет лямбду в контексте snapshot** — snapshot становится источником истины для любого состояния: все чтения внутри лямбды получают значения из snapshot. Так Compose и другие библиотеки могут выполнять логику работы с состоянием в контексте заданного snapshot — локально в потоке, до возврата из `enter`. Другие потоки не затрагиваются.

В примере после обновления имя «Fido», но при чтении внутри `enter` возвращается «Spot» — **значение на момент создания snapshot**.

Внутри `enter` в зависимости от типа snapshot (только чтение или мутабельный) возможны и чтение, и запись. Мутабельные snapshot разберём позже.

Snapshot, созданный через `Snapshot.takeSnapshot()`, только для чтения. Записывать в его state объекты нельзя — будет исключение.

Compose предоставляет реализацию контракта `Snapshot`, позволяющую мутировать состояние: `MutableSnapshot`. Есть и другие реализации. Иерархия типов:

```kotlin
1 sealed class Snapshot(...) {
2   class ReadonlySnapshot(...) : Snapshot() {...}
3   class NestedReadonlySnapshot(...) : Snapshot() {...}
4   open class MutableSnapshot(...) : Snapshot() {...}
5   class NestedMutableSnapshot(...) : MutableSnapshot() {...}
6   class GlobalSnapshot(...) : MutableSnapshot() {...}
7   class TransparentObserverMutableSnapshot(...) : MutableSnapshot() {...}
8 }
```
*Snapshot.kt*

Кратко по типам:

- **ReadonlySnapshot:** хранимые state объекты только читаются.
- **MutableSnapshot:** хранимые state объекты можно читать и менять.
- **NestedReadonlySnapshot** и **NestedMutableSnapshot:** дочерние snapshot, так как snapshot образуют дерево.
- **GlobalSnapshot:** мутабельный snapshot глобального (общего) состояния программы, корень дерева snapshot.
- **TransparentObserverMutableSnapshot:** не изолирует состояние, только уведомляет наблюдателей при чтении/записи. Все его state records помечаются невалидными. Его ID всегда совпадает с родительским; операции выглядят как выполненные в родителе.

## Дерево snapshot

**Snapshot образуют дерево.** Есть вложенные только для чтения и мутабельные. Корень дерева — `GlobalSnapshot`. Вложенные snapshot можно освобождать независимо, **оставляя родителя активным**. Это часто используется при **subcomposition** (глава 2): subcomposition создаётся inline для независимой инвалидации. Примеры: элемент lazy list, `BoxWithConstraints`, `SubcomposeLayout`, `VectorPainter`. При subcomposition создаётся вложенный snapshot для изоляции состояния; когда subcomposition исчезает, snapshot освобождается, родительская composition и snapshot остаются. Изменения вложенного snapshot распространяются в родителя.

У всех типов snapshot есть методы вида `takeNestedSnapshot()` / `takeNestedMutableSnapshot()`. Read-only дочерний snapshot можно создать от любого типа; мутабельный — только от мутабельного (или от глобального).

## Snapshots и потоки

Snapshot стоит представлять как структуры вне привязки к потоку. Поток может иметь текущий snapshot, но snapshot **не привязаны к потоку**. Поток может входить и выходить из snapshot; дочерний snapshot может быть «введён» в другом потоке. Параллельная работа — один из сценариев. Несколько потоков могут работать со своими snapshot; при введении мутабельных snapshot мы увидим, как дочерние должны сообщать изменения родителю. Коллизии между потоками будут обнаруживаться и обрабатываться. Текущий snapshot потока: `Snapshot.current` (если есть — потоковый, иначе глобальный).

## Наблюдение за чтениями и записями

Рантайм Compose умеет запускать recomposition при записи в наблюдаемое состояние. Разберём связь с системой state snapshot — начнём с наблюдения за чтениями.

При вызове `Snapshot.takeSnapshot()` возвращается `ReadonlySnapshot`. В него можно передать необязательный `readObserver`; он будет вызываться при каждом чтении state из snapshot **внутри вызова `enter`**:

```kotlin
1 // simple observer to track the total number of reads
2 val snapshot = Snapshot.takeSnapshot { reads++ }
3 // ...
4 snapshot.enter { /* some state reads */ }
5 // ...
```
*ReadOnlySnapshot.kt*

Пример — `snapshotFlow(block: () -> T): Flow<T>`: превращает `State<T>` в `Flow`. При коллекции выполняется блок и эмитируется результат; при мутации прочитанного State Flow эмитирует новое значение. Для этого нужно записывать все чтения state. Это делается через read-only snapshot с read observer, который сохраняет их в `Set`:

```kotlin
1 fun &lt;T&gt; snapshotFlow(block: () -&gt; T): Flow&lt;T&gt; {
2   // ...
3   snapshot.takeSnapshot { readSet.add(it) }
4   // ...
5   // Do something with the Set
6 }
```
*SnapshotFlow.kt*

У read-only snapshot уведомляется не только его read observer, но и read observer родителя — чтение во вложенном snapshot должно быть видно всем родителям.

Для наблюдения за **записями** можно передать `writeObserver` при создании **мутабельного** snapshot: `Snapshot.takeMutableSnapshot()`. Пример — `Recomposer`, отслеживающий чтения и записи в Composition для автоматического запуска recomposition:

```kotlin
 1 private fun readObserverOf(composition: ControlledComposition): (Any) -&gt; Unit {
 2   return { value -&gt; composition.recordReadOf(value) } // recording reads
 3 }
 4 
 5 private fun writeObserverOf(
 6   composition: ControlledComposition,
 7   modifiedValues: IdentityArraySet&lt;Any&gt;?
 8 ): (Any) -&gt; Unit {
 9   return { value -&gt;
10     composition.recordWriteOf(value) // recording writes
11     modifiedValues?.add(value)
12   }
13 }
14     
15 private inline fun &lt;T&gt; composing(
16   composition: ControlledComposition,
17   modifiedValues: IdentityArraySet&lt;Any&gt;?,
18   block: () -&gt; T
19 ): T {
20   val snapshot = Snapshot.takeMutableSnapshot(
21     readObserverOf(composition),
22     writeObserverOf(composition, modifiedValues)
23   )
24   try {
25     return snapshot.enter(block)
26   } finally {
27     applyAndCheck(snapshot)
28   }
29 }
```
*Recomposer.kt*

Функция `composing` вызывается при первичной composition и при каждой recomposition. Используется `MutableSnapshot`; все чтения и записи в `block` отслеживаются Composition. Блок — по сути код composition/recomposition (выполнение Composable). При записи в snapshot state инвалидируются соответствующие `RecomposeScope`, прочитавшие этот state, и запускается recomposition. В конце `applyAndCheck(snapshot)` распространяет изменения в другие snapshot и глобальное состояние.

Сигнатуры наблюдателей:

```kotlin
1 readObserver: ((Any) -&gt; Unit)?
2 writeObserver: ((Any) -&gt; Unit)?
```
*ReadAndWriteObservers.kt*

Есть утилита `Snapshot.observe(readObserver, writeObserver, block)` для наблюдения в текущем потоке. Её использует, например, `derivedStateOf`. Там же используется `TransparentObserverMutableSnapshot` — создаётся родительский snapshot только для уведомления наблюдателей о чтениях.

## MutableSnapshot

В мутабельном snapshot любой state объект имеет то же значение, что при создании snapshot, **если только он не изменён локально в этом snapshot**. Все изменения в `MutableSnapshot` **изолированы** от других snapshot. Распространение идёт снизу вверх: вложенный мутабельный snapshot сначала применяет свои изменения, затем они распространяются в родителя или в глобальный snapshot (если это корень). Вызов `NestedMutableSnapshot#apply` или `MutableSnapshot#apply`.

По kdoc рантайма: *Composition использует мутабельные snapshot, чтобы изменения в Composable временно изолировать от глобального состояния и применить их при применении composition. При неудаче MutableSnapshot.apply snapshot и изменения отбрасываются и планируется новый расчёт composition.*

При применении composition (через Applier) изменения мутабельных snapshot применяются и уведомляют родителя или глобальный snapshot. Жизненный цикл мутабельного snapshot завершается вызовом `apply` и/или `dispose`. Изменения при `apply` применяются **атомарно**. Если snapshot освобождён без применения, все отложенные изменения отбрасываются.

Пример `apply` в клиентском коде:

```kotlin
 1 class Address {
 2   var streetname: MutableState&lt;String&gt; = mutableStateOf(&quot;&quot;)
 3 }
 4 
 5 fun main() {
 6   val address = Address()
 7   address.streetname.value = &quot;Some street&quot;
 8 
 9   val snapshot = Snapshot.takeMutableSnapshot()
10   println(address.streetname.value)
11   snapshot.enter {
12     address.streetname.value = &quot;Another street&quot;
13     println(address.streetname.value)
14   }
15   println(address.streetname.value)
16   snapshot.apply()
17   println(address.streetname.value)
18 }
19 
20 // This prints the following:
21 
22 // Some street
23 // Another street
24 // Some street
25 // Another street
```
*ApplyMutableSnapshotSample.kt*

Внутри `enter` видно «Another street»; снаружи до `apply` — снова «Some street». После `apply` — «Another street». Есть сокращение: `Snapshot.withMutableSnapshot { ... }` — гарантирует вызов `apply` в конце.

Идея та же, что у списка изменений в Composer (глава 3): записать/отложить, применить в нужном порядке. Наблюдатели применения: `Snapshot.registerApplyObserver`.

## GlobalSnapshot и вложенные snapshot

`GlobalSnapshot` — мутабельный snapshot глобального состояния. Он не вкладывается; он один и является корнем дерева snapshot. Его не «применяют» — его **продвигают**: `Snapshot.advanceGlobalSnapshot()` создаёт новый глобальный snapshot, перенося в него валидное состояние предыдущего; apply observers уведомляются. `dispose()` у него не вызывают — «освобождение» тоже через продвижение.

На JVM глобальный snapshot создаётся при инициализации системы snapshot. Менеджер глобального snapshot запускается при создании Composer. Каждая composition (первичная и recomposition) создаёт свой вложенный мутабельный snapshot и регистрирует read/write observers. Subcomposition могут создавать свои вложенные snapshot. При создании Composition вызывается `GlobalSnapshotManager.ensureStarted()` — начинается наблюдение за записями в глобальное состояние и периодическая диспетчеризация уведомлений apply в контексте `AndroidUiDispatcher.Main`.

## StateObject и StateRecord

При каждой записи создаётся новая версия (copy-on-write). В памяти может храниться несколько версий одного snapshot state объекта. Внутри такой объект моделируется как `StateObject`, каждая версия — `StateRecord`. Запись валидна для snapshot, если её ID меньше или равен ID snapshot и она не в множестве `invalid` и не помечена невалидной. Невалидными считаются записи, созданные после текущего snapshot, в snapshot, уже открытом при создании текущего, или в snapshot, освобождённом до применения.

Интерфейс в коде:

```kotlin
 1 interface StateObject {
 2   val firstStateRecord: StateRecord
 3   
 4   fun prependStateRecord(value: StateRecord)
 5   
 6   fun mergeRecords(
 7     previous: StateRecord,
 8     current: StateRecord,
 9     applied: StateRecord
10   ): StateRecord? = null
11 }
```
*Snapshot.kt*

`mutableStateOf(value, policy)` возвращает `SnapshotMutableState` — `StateObject` со связным списком записей. При чтении обходится список в поисках **последней валидной** записи. `mergeRecords` нужна для автоматического слияния конфликтов при применении.

`StateRecord` привязан к ID snapshot, имеет `next`, методы `assign` и `create`. У `mutableStateOf` записи типа `StateStateRecord` (обёртка над `value: T`). У `mutableStateListOf` — `SnapshotStateList` с записями `StateListStateRecord` (используют `PersistentList`).

## Чтение и запись состояния

При чтении обходится список записей StateObject в поисках последней валидной для текущего snapshot. Геттер `value` в `SnapshotMutableStateImpl` вызывает `next.readable(this).value` (итерация + уведомление read observers). Сеттер через `withCurrent` и `overwritable`: проверка эквивалентности по `SnapshotMutationPolicy`, при отличии — запись через writable record и уведомление write observers.

## Удаление и переиспользование устаревших записей

Отслеживается минимальный открытый snapshot ID. Если запись валидна, но не видна в нём, её можно безопасно переиспользовать. Обычно у мутабельного state 1–2 записи. При применении snapshot затемнённая запись переиспользуется; при dispose до apply все записи помечаются невалидными и могут переиспользоваться сразу.

## Распространение изменений

Закрытие snapshot — удаление его ID из множества открытых; тогда его записи становятся видимыми новым snapshot. Продвижение — закрытие и сразу создание нового snapshot с новым ID. Глобальный snapshot не применяют, а продвигают. При `snapshot.apply()` локальные изменения мутабельного snapshot распространяются в родителя или в глобальное состояние. Сначала проверяются коллизии и при возможности делается merge (оптимистично). Для каждого изменения сравнивается с текущим значением; при отличии с учётом merge создаётся новая запись и дописывается в список. При ошибке применяется тот же путь, что и при отсутствии локальных изменений (закрытие, продвижение глобального, уведомление apply observers). Для вложенных мутабельных snapshot изменения добавляются в множество изменённых родителя и ID вложенного удаляется из множества невалидных родителя.

## Слияние конфликтов записи

При слиянии для каждого изменённого state берутся текущее значение в родителе/глобальном, предыдущее и значение после применения; слияние делегируется объекту состояния (политика слияния). Сейчас в рантайме ни одна политика не выполняет настоящее слияние — при коллизии выбрасывается исключение. Compose избегает коллизий за счёт уникальных ключей доступа к state (например, `remember` в Composable). `mutableStateOf` по умолчанию использует `StructuralEqualityPolicy` — глубокое сравнение, включая ключ объекта. Можно задать свой `SnapshotMutationPolicy`. Пример из документации — политика-счётчик для `MutableState<Int>`: `equivalent(a,b) = (a==b)`, `merge(previous, current, applied) = current + (applied - previous)`. Тогда две параллельные «транзакции», добавляющие 10 и 20, дадут в итоге 30.

```kotlin
1 fun counterPolicy(): SnapshotMutationPolicy&lt;Int&gt; = object : SnapshotMutationPolicy&lt;I\
2 nt&gt; {
3   override fun equivalent(a: Int, b: Int): Boolean = a == b
4   override fun merge(previous: Int, current: Int, applied: Int) =
5     current + (applied - previous)
6 }
```
*CounterPolicy.kt*

```kotlin
 1 val state = mutableStateOf(0, counterPolicy())
 2 val snapshot1 = Snapshot.takeMutableSnapshot()
 3 val snapshot2 = Snapshot.takeMutableSnapshot()
 4 try {
 5   snapshot1.enter { state.value += 10 }
 6   snapshot2.enter { state.value += 20 }
 7   snapshot1.apply().check()
 8   snapshot2.apply().check()
 9 } finally {
10   snapshot1.dispose()
11   snapshot2.dispose()
12 }
13 
14 // State is now 30 as the changes made in the snapshots are added together.
```
*CounterPolicy2.kt*

Можно задавать политики, допускающие коллизии и разрешающие их через `merge`.