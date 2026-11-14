(ql:quickload "cffi")

;;;; epoll.lisp — Linux epoll(7) wrapper for SBCL via CFFI
;;;; 依赖：cffi 包，可通过 (ql:quickload :cffi) 安装

(defpackage #:epoll
  (:use #:cl #:cffi)
  (:export
   ;; 事件常量
   #:+epoll-in+
   #:+epoll-out+
   #:+epoll-err+
   #:+epoll-hup+
   #:+epoll-rdhup+
   #:+epoll-pri+
   #:+epoll-et+
   #:+epoll-one-shot+
   ;; epoll_ctl 操作常量
   #:+epoll-ctl-add+
   #:+epoll-ctl-mod+
   #:+epoll-ctl-del+
   ;; 数据结构
   #:epoll-event
   #:epoll-event-events
   #:epoll-event-data-fd
   ;; 核心函数
   #:epoll-create
   #:epoll-close
   #:epoll-control-add
   #:epoll-control-modify
   #:epoll-control-delete
   #:epoll-wait
   ;; 工具函数
   #:event-flags-set-p
   #:event-flags-to-list))

(in-package #:epoll)

;;; ============================================================================
;;; 1. epoll 事件常量（来自 <sys/epoll.h>）
;;; ============================================================================

(defconstant +epoll-in+      #x001  "可读事件")
(defconstant +epoll-pri+     #x002  "高优先级可读事件")
(defconstant +epoll-out+     #x004  "可写事件")
(defconstant +epoll-err+     #x008  "错误事件（始终被监听，无需显式设置）")
(defconstant +epoll-hup+     #x010  "对端挂断（始终被监听，无需显式设置）")
(defconstant +epoll-rdhup+   #x2000 "对端关闭写端（半关闭）")
(defconstant +epoll-et+      #x80000000 "边缘触发模式")
(defconstant +epoll-one-shot+ #x40000000 "一次性触发，事件触发后该fd不再被监听")

(defconstant +epoll-ctl-add+ 1 "epoll_ctl: 添加文件描述符")
(defconstant +epoll-ctl-mod+ 2 "epoll_ctl: 修改文件描述符监听事件")
(defconstant +epoll-ctl-del+ 3 "epoll_ctl: 删除文件描述符")

;;; ============================================================================
;;; 2. epoll_event 结构体定义
;;; ============================================================================
;; Linux 上 struct epoll_event 布局：
;;   typedef union epoll_data {
;;       void    *ptr;
;;       int      fd;
;;       uint32_t u32;
;;       uint64_t u64;
;;   } epoll_data_t;
;;
;;   struct epoll_event {
;;       uint32_t     events;  /* Epoll events */
;;       epoll_data_t data;    /* User data variable */
;;   };
;; 注意：在 64 位系统上，由于对齐，data 从偏移 4 开始，整体大小 12 字节？
;; 实际上 x86_64 上 epoll_event 是 12 字节（4+8），但有些系统按 16 字节对齐。
;; 为安全起见，我们使用 16 字节布局：uint32 events + 4 字节填充 + uint64 data

(defcstruct (epoll-event :size 16)
  (events :uint32 :offset 0)
  (data-fd :int :offset 8))   ; 使用 data 联合体中的 fd 字段，偏移 8 字节

;;; ============================================================================
;;; 3. 底层 C 函数绑定
;;; ============================================================================

;; int epoll_create1(int flags);
;; flags 传 0 等价于旧的 epoll_create()
(defcfun ("epoll_create1" %epoll-create1) :int
  (flags :int))

;; int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event);
(defcfun ("epoll_ctl" %epoll-ctl) :int
  (epfd :int)
  (op :int)
  (fd :int)
  (event :pointer))

;; int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout);
(defcfun ("epoll_wait" %epoll-wait) :int
  (epfd :int)
  (events :pointer)
  (max-events :int)
  (timeout :int))

;; int close(int fd);
(defcfun ("close" %unix-close) :int
  (fd :int))

;;; ============================================================================
;;; 4. 高层 Lisp 接口
;;; ============================================================================

(defun epoll-create ()
  "创建一个新的 epoll 实例，返回 epoll 文件描述符。
失败时返回 -1，并设置 errno。
使用完毕后必须调用 epoll-close 关闭。"
  (%epoll-create1 0))

(defun epoll-close (epoll-fd)
  "关闭 epoll 文件描述符，释放内核资源。
成功返回 0，失败返回 -1。"
  (%unix-close epoll-fd))

(defun epoll-control-add (epoll-fd target-fd event-flags)
  "向 epoll 实例添加一个文件描述符并指定监听事件。
- epoll-fd: epoll 实例的文件描述符
- target-fd: 要监听的目标文件描述符
- event-flags: 事件标志位组合，例如 (logior +epoll-in+ +epoll-et+)
成功返回 0，失败返回 -1。"
  (with-foreign-object (ev '(:struct epoll-event))
    (setf (foreign-slot-value ev '(:struct epoll-event) 'events) event-flags
          (foreign-slot-value ev '(:struct epoll-event) 'data-fd) target-fd)
    (%epoll-ctl epoll-fd +epoll-ctl-add+ target-fd ev)))

(defun epoll-control-modify (epoll-fd target-fd event-flags)
  "修改已注册文件描述符的监听事件。
参数含义同 epoll-control-add。
成功返回 0，失败返回 -1。"
  (with-foreign-object (ev '(:struct epoll-event))
    (setf (foreign-slot-value ev '(:struct epoll-event) 'events) event-flags
          (foreign-slot-value ev '(:struct epoll-event) 'data-fd) target-fd)
    (%epoll-ctl epoll-fd +epoll-ctl-mod+ target-fd ev)))

(defun epoll-control-delete (epoll-fd target-fd)
  "从 epoll 实例中移除一个文件描述符。
成功返回 0，失败返回 -1。"
  ;; Linux 内核中 EPOLL_CTL_DEL 可以忽略 event 参数，但为了兼容性仍传入空指针
  (%epoll-ctl epoll-fd +epoll-ctl-del+ target-fd (null-pointer)))

(defun epoll-wait (epoll-fd max-events timeout-ms)
  "等待 epoll 事件，返回就绪事件列表。
- max-events: 单次最多返回的事件数量
- timeout-ms: 超时毫秒数，-1 表示永久阻塞，0 表示立即返回
返回值：list of (fd . event-flags)，即每个元素是一个 cons，car 是就绪 fd，cdr 是事件标志位。
出错时返回 nil（可通过 errno 判断原因）。"
  (let ((ready-list nil))
    (with-foreign-object (events '(:struct epoll-event) max-events)
      (let ((n-ready (%epoll-wait epoll-fd events max-events timeout-ms)))
        (when (plusp n-ready)
          (dotimes (i n-ready)
            (let* ((ev-ptr (mem-aptr events '(:struct epoll-event) i))
                   (fd (foreign-slot-value ev-ptr '(:struct epoll-event) 'data-fd))
                   (ev-flags (foreign-slot-value ev-ptr '(:struct epoll-event) 'events)))
              (push (cons fd ev-flags) ready-list))))))
    (nreverse ready-list)))

;;; ============================================================================
;;; 5. 工具函数
;;; ============================================================================

(defun event-flags-set-p (event-flags flag)
  "检查事件标志位中是否包含指定 flag。
示例：(event-flags-set-p flags +epoll-in+)"
  (not (zerop (logand event-flags flag))))

(defun event-flags-to-list (event-flags)
  "将事件标志位整数转换为可读的关键词列表，便于调试。"
  (let ((result nil))
    (dolist (pair `((,+epoll-in+      :in)
                    (,+epoll-out+     :out)
                    (,+epoll-err+     :err)
                    (,+epoll-hup+     :hup)
                    (,+epoll-rdhup+   :rdhup)
                    (,+epoll-pri+     :pri)
                    (,+epoll-et+      :edge-triggered)
                    (,+epoll-one-shot+ :one-shot)))
      (when (event-flags-set-p event-flags (first pair))
        (push (second pair) result)))
    (nreverse result)))
