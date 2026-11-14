# cl-epoll
common-lisp epoll written by doubao

```common-lisp
(ql:quickload "cffi")

(setf my-socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
(setf my-address (sb-bsd-sockets:make-inet-address "127.0.0.1"))
(sb-bsd-sockets:socket-bind my-socket my-address 8888 :reuse-address t)
(sb-bsd-sockets:socket-listen my-socket 5)

(defvar *epfd* (epoll-create))

(setf my-client (sb-bsd-sockets:socket-accept my-socket))
(setf my-fd (sb-bsd-sockets:socket-file-descriptor my-client))

;; 添加一个 fd 监听可读事件
(epoll-control-add *epfd* my-fd (logior +epoll-in+))

;; 等待事件，最多返回 32 个，永久阻塞
(defvar *ready* (epoll-wait *epfd* 32 -1))

;; 处理就绪事件
(dolist (ev *ready*)
  (let ((fd (car ev)))
    (format t "~A" fd)
    (finish-output)))

```
