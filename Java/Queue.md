# Queue

> Queue 在算法面试和并发面试都常考。考点：
> ① **Queue / Deque** 接口体系——12 个方法分两套
> ② **ArrayDeque vs LinkedList** —— 选哪个做栈/队列
> ③ **PriorityQueue** 是什么数据结构、O(log n) 怎么来的
> ④ **BlockingQueue** 七大实现（详见 [Concurrency](../Concurrency/阻塞队列.md)）
> ⑤ **ConcurrentLinkedQueue** 怎么实现无锁

---

## 一、Queue / Deque 体系

```
                  Iterable
                     │
                Collection
                     │
                  Queue
                  /     \
           Deque         BlockingQueue
           /              /         \
    ArrayDeque    LinkedBlockingQueue   ArrayBlockingQueue
    LinkedList    SynchronousQueue       PriorityBlockingQueue
                  DelayQueue / LinkedTransferQueue ...
                  
    PriorityQueue（直接实现 Queue）
    ConcurrentLinkedQueue（无锁队列）
```

### 1.1 Queue 接口（FIFO）

```java
public interface Queue<E> extends Collection<E> {
    // 抛异常版          // 返回 false/null 版
    boolean add(E e);     boolean offer(E e);     // 入队
    E remove();           E poll();               // 出队
    E element();          E peek();               // 看队首不出
}
```

→ **每个操作两套方法**：抛异常 vs 返回特殊值。

### 1.2 Deque 接口（双端）

```java
public interface Deque<E> extends Queue<E> {
    void addFirst(E e);    boolean offerFirst(E e);
    void addLast(E e);     boolean offerLast(E e);
    E removeFirst();       E pollFirst();
    E removeLast();        E pollLast();
    E getFirst();          E peekFirst();
    E getLast();           E peekLast();
    
    // 栈语义
    void push(E e);        // 等价 addFirst
    E pop();               // 等价 removeFirst
}
```

→ **既能当队列又能当栈**。push/pop 是 addFirst/removeFirst 的别名。

---

## 二、抛异常 vs 返回特殊值

| 操作 | 抛异常版 | 返回值版 | 推荐 |
| --- | --- | --- | --- |
| 入队 | `add(e)` 满抛 IllegalStateException | `offer(e)` 满返回 false | **offer** |
| 出队 | `remove()` 空抛 NoSuchElementException | `poll()` 空返回 null | **poll** |
| 看首 | `element()` 空抛 NoSuchElementException | `peek()` 空返回 null | **peek** |

→ 生产**永远用返回值版**，避免异常控制流。

---

## 三、Deque 的两个主要实现

### 3.1 ArrayDeque

```java
public class ArrayDeque<E> implements Deque<E> {
    transient Object[] elements;
    transient int head;
    transient int tail;
}
```

数据结构：**循环数组**（ring buffer）。

- 默认容量 16
- 头 / 尾用 `head`、`tail` 索引
- 满了扩容 **2x**
- 数组下标用 `(index) & (length - 1)` 算（length 必须 2 的幂）

**特征**：

- 头尾增删 O(1)（无锁，快）
- **不允许 null**（null 用作空标识）
- 不是线程安全

### 3.2 LinkedList

参见 [List - LinkedList](./List.md#三linkedlist)。同时实现 `List` 和 `Deque`。

### 3.3 ArrayDeque vs LinkedList

| 维度 | ArrayDeque | LinkedList |
| --- | --- | --- |
| 数据结构 | 循环数组 | 双向链表 |
| 内存 | 紧凑 | 每节点多 24B |
| CPU 缓存 | ✅ 友好 | ❌ 跳跃 |
| null 元素 | ❌ | ✅ |
| 实现 List | ❌ | ✅ |
| 头尾增删 | O(1) | O(1) |
| 性能 | **几乎永远更快** | 慢 |

→ **做队列 / 栈用 ArrayDeque，永远不要用 LinkedList**。

```java
// ❌ 老写法
Stack<Integer> stack = new Stack<>();         // 老 API + 全方法 synchronized，性能差
Deque<Integer> stack = new LinkedList<>();    // 慢

// ✅ 新写法
Deque<Integer> stack = new ArrayDeque<>();
stack.push(1); stack.pop();

Queue<Integer> queue = new ArrayDeque<>();
queue.offer(1); queue.poll();
```

> **小坑**：`java.util.Stack` 已是历史包袱（继承自 Vector），生产**别用**——所有方法 synchronized，又是 Vector 子类。

---

## 四、PriorityQueue

### 4.1 数据结构：二叉小顶堆

```java
public class PriorityQueue<E> implements Queue<E> {
    transient Object[] queue;       // 数组实现的二叉堆
    private int size = 0;
    private final Comparator<? super E> comparator;
}
```

**二叉堆的数组实现**（不是树节点）：

```
索引：     0     1     2     3     4     5     6
数组：    [1]  [3]  [2]  [7]  [5]  [4]  [6]

逻辑上：
            1                          ← root（最小）
          /   \
         3     2
        / \   / \
       7   5 4   6

子节点公式：left = 2i+1, right = 2i+2
父节点公式：parent = (i-1)/2
```

### 4.2 操作复杂度

| 操作 | 时间复杂度 | 实现 |
| --- | --- | --- |
| `peek()` | O(1) | 返回 queue[0] |
| `offer(e)` | O(log n) | 加到末尾 + sift-up（向上比较交换） |
| `poll()` | O(log n) | 取 queue[0] + 末尾移到首 + sift-down |

### 4.3 默认是小顶堆

```java
PriorityQueue<Integer> pq = new PriorityQueue<>();
pq.offer(5); pq.offer(1); pq.offer(3);
pq.poll();    // 1（最小先出）
```

实现大顶堆：

```java
PriorityQueue<Integer> pq = new PriorityQueue<>(Comparator.reverseOrder());
```

### 4.4 经典用法

**Top K 元素**：

```java
// 求最大的 k 个
PriorityQueue<Integer> minHeap = new PriorityQueue<>();
for (int x : arr) {
    minHeap.offer(x);
    if (minHeap.size() > k) minHeap.poll();
}
return minHeap;     // 堆里就是最大的 k 个
```

**任务调度**：按优先级出队。

**合并 K 个有序链表**：把每个链表头放进堆，每次取最小。

### 4.5 注意

- **不保证 iterator 顺序** —— 内部是堆数组，遍历不是排序后的顺序
- **不允许 null**
- **不是线程安全** —— 多线程要用 `PriorityBlockingQueue`

---

## 五、ConcurrentLinkedQueue —— 无锁队列

```java
public class ConcurrentLinkedQueue<E> extends AbstractQueue<E> {
    private static class Node<E> {
        volatile E item;
        volatile Node<E> next;
    }
    
    private transient volatile Node<E> head;
    private transient volatile Node<E> tail;
}
```

特征：

- **基于 Michael & Scott 1996 年的无锁队列算法**
- 通过 **CAS** 操作 `tail.next`、`head` 实现并发
- **永远不阻塞**——offer/poll 都不阻塞
- 没有 BlockingQueue 的 take/put 阻塞语义

适用场景：**无界、高并发、非阻塞**——比如生产消费速率匹配的场景。

> 但 size() 是 **O(n)**——遍历计数（无法 O(1) 维护一致 size）。生产**慎用 size()**。

---

## 六、BlockingQueue（简）

详细见 [Concurrency / 阻塞队列](../Concurrency/阻塞队列.md)。

七大实现速查：

| 实现 | 数据结构 | 边界 | 公平 |
| --- | --- | --- | --- |
| `ArrayBlockingQueue` | 循环数组 | 有界 | 可选 |
| `LinkedBlockingQueue` | 链表 | 默认无界（Integer.MAX_VALUE）| ❌ |
| `PriorityBlockingQueue` | 堆 | 无界 | ❌ |
| `DelayQueue` | 堆 + 延时 | 无界 | ❌ |
| `SynchronousQueue` | 无容量（一次一个） | 0 | 可选 |
| `LinkedTransferQueue` | 链表 + transfer | 无界 | ❌ |
| `LinkedBlockingDeque` | 链表 + 双端 | 默认无界 | ❌ |

阻塞 API：

```java
queue.put(e);        // 满则阻塞
queue.take();        // 空则阻塞
queue.offer(e, 1, TimeUnit.SECONDS);   // 超时入队
queue.poll(1, TimeUnit.SECONDS);        // 超时出队
```

---

## 七、生产踩坑

### 7.1 用 LinkedList 做队列

**现象**：高并发场景下队列吞吐不达预期。
**根因**：LinkedList 内存碎片 + 缓存 miss + 每节点 24B 开销。
**修复**：换 ArrayDeque（单线程）或 ConcurrentLinkedQueue（多线程）。

### 7.2 PriorityQueue iterator 不是排序

```java
PriorityQueue<Integer> pq = new PriorityQueue<>(Arrays.asList(5, 1, 3));
for (Integer x : pq) System.out.println(x);    // 1, 3, 5? ⚠ 不一定！
```

→ iterator 遍历的是堆**数组顺序**。要排序遍历必须**逐个 poll**：

```java
while (!pq.isEmpty()) System.out.println(pq.poll());   // ✅ 1, 3, 5
```

### 7.3 LinkedBlockingQueue 默认无界

**现象**：用 `LinkedBlockingQueue` 做线程池任务队列，OOM。
**根因**：默认 `Integer.MAX_VALUE` 无界——任务来得快、消费慢，堆积到 OOM。
**修复**：**永远显式传容量**：

```java
new LinkedBlockingQueue<>(1000);   // ✅
```

→ 这就是为什么阿里规约禁用 `Executors.newFixedThreadPool`——它内部用无界 LinkedBlockingQueue。

### 7.4 ConcurrentLinkedQueue.size() 慢

**现象**：用 `if (queue.size() > limit)` 控制流量，发现 CPU 高。
**根因**：size() 遍历整个链表 O(n)。
**修复**：自己维护 AtomicInteger 计数；或不用 size，用 `isEmpty()`。

### 7.5 用错 add/offer

```java
ArrayBlockingQueue<Integer> q = new ArrayBlockingQueue<>(3);
q.add(1); q.add(2); q.add(3);
q.add(4);    // ⚠ IllegalStateException

q.offer(4);  // ✅ 返回 false
```

生产代码用 offer，避免业务代码包一层 try-catch。

---

## 八、答题模板（60 秒话术）

> Queue 是 FIFO 队列接口，**Deque** 双端队列继承 Queue，**两套 API**：抛异常版（add/remove/element）、返回值版（offer/poll/peek）——生产永远用返回值版。
>
> **ArrayDeque** 是循环数组，做队列、栈都几乎永远比 LinkedList 快——CPU 缓存友好、内存紧凑。Stack 类已废，**栈用 ArrayDeque.push/pop**。
>
> **PriorityQueue** 是基于数组的二叉小顶堆，offer/poll **O(log n)**、peek O(1)。常用于 **Top K**、任务调度、合并 K 个有序链表。**遍历不是排序顺序**，要排序必须逐个 poll。
>
> **ConcurrentLinkedQueue** 是 Michael-Scott 无锁队列，CAS 实现 offer/poll，**不阻塞**。但 size() 是 O(n)，慎用。
>
> **BlockingQueue** 七大实现里：**LinkedBlockingQueue 默认无界（要显式给容量否则 OOM）**、SynchronousQueue 容量 0（生产消费一对一交接）、DelayQueue 用于延时任务。

---

## 九、相关文档

- [List](./List.md) — LinkedList 同时实现 List 和 Deque
- [集合框架总览](./集合类.md) — 集合体系
- [Concurrency / 阻塞队列](../Concurrency/阻塞队列.md) — BlockingQueue 七大实现详解
- [Concurrency / 线程池](../Concurrency/线程池.md) — 线程池任务队列选型
- [Concurrency / ForkJoinPool](../Concurrency/ForkJoinPool.md) — 工作窃取队列
