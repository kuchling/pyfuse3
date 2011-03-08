'''
misc.pxi

This file defines various functions that are used internally by
LLFUSE. It is included by llfuse.pyx.

Copyright (C) Nikolaus Rath <Nikolaus@rath.org>

This file is part of LLFUSE (http://python-llfuse.googlecode.com).
LLFUSE can be distributed under the terms of the GNU LGPL.
'''


log = logging.getLogger("fuse")

cdef object operations
cdef char* mountpoint = NULL
cdef fuse_session* session = NULL
cdef fuse_chan* channel = NULL
cdef fuse_lowlevel_ops fuse_ops


cdef object fill_entry_param(object attr, fuse_entry_param* entry):
    entry.ino = attr.st_ino
    entry.generation = attr.generation
    entry.entry_timeout = attr.entry_timeout
    entry.attr_timeout = attr.attr_timeout

    fill_c_stat(attr, &entry.attr)

cdef object fill_c_stat(object attr, c_stat* stat):
    stat.st_ino = attr.st_ino
    stat.st_mode = attr.st_mode
    stat.st_nlink = attr.st_nlink
    stat.st_uid = attr.st_uid
    stat.st_gid = attr.st_gid
    stat.st_rdev = attr.st_rdev
    stat.st_size = attr.st_size
    stat.st_blksize = attr.st_blksize
    stat.st_blocks = attr.st_blocks

    stat.st_atime = attr.st_atime
    stat.st_ctime = attr.st_ctime
    stat.st_mtime = attr.st_mtime
    
    SET_ATIME_NS(stat, (attr.st_atime - stat.st_atime) * 1e9)
    SET_CTIME_NS(stat, (attr.st_ctime - stat.st_ctime) * 1e9)
    SET_MTIME_NS(stat, (attr.st_mtime - stat.st_mtime) * 1e9)

cdef object fill_statvfs(object attr, statvfs* stat):
    stat.f_bsize = attr.f_bsize
    stat.f_frsize = attr.f_frsize
    stat.f_blocks = attr.f_blocks
    stat.f_bfree = attr.f_bfree
    stat.f_bavail = attr.f_bavail
    stat.f_files = attr.f_files
    stat.f_ffree = attr.f_ffree
    stat.f_favail = attr.f_favail
    
cdef object strerror(errno):
    try:
        return os.strerror(errno)
    except ValueError:
        return 'errno: %d' % errno

cdef int handle_exc(char* fn, object e, fuse_req_t req):
    '''Try to call operations.handle_exc and fuse_reply_err'''
    
    log.exception('operations.%s() raised exception.', fn)
    try:
        with lock:
            operations.handle_exc(fn, e)
    except BaseException as e:
        log.exception('operations.handle_exc() raised exception itself')

    if req is NULL:
        return 0
    else:
        return fuse_reply_err(req, errno.EIO)
        
cdef object get_request_context(fuse_req_t req):
    '''Get RequestContext() object'''
    
    cdef const_fuse_ctx* context

    context = fuse_req_ctx(req)
    ctx = RequestContext()
    ctx.pid = context.pid
    ctx.uid = context.uid
    ctx.gid = context.gid

    return ctx


cdef void init_fuse_ops():
    '''Initialize fuse_lowlevel_ops structure'''

    string.memset(&fuse_ops, 0, sizeof(fuse_lowlevel_ops))

    fuse_ops.init = fuse_init
    fuse_ops.destroy = fuse_destroy
    fuse_ops.lookup = fuse_lookup
    fuse_ops.forget = fuse_forget
    fuse_ops.getattr = fuse_getattr
    fuse_ops.setattr = fuse_setattr
    fuse_ops.readlink = fuse_readlink
    fuse_ops.mknod = fuse_mknod
    fuse_ops.mkdir = fuse_mkdir
    fuse_ops.unlink = fuse_unlink
    fuse_ops.rmdir = fuse_rmdir
    fuse_ops.symlink = fuse_symlink
    fuse_ops.rename = fuse_rename
    fuse_ops.link = fuse_link
    fuse_ops.open = fuse_open
    fuse_ops.read = fuse_read
    fuse_ops.write = fuse_write
    fuse_ops.flush = fuse_flush
    fuse_ops.release = fuse_release
    fuse_ops.fsync = fuse_fsync
    fuse_ops.opendir = fuse_opendir
    fuse_ops.readdir = fuse_readdir
    fuse_ops.releasedir = fuse_releasedir
    fuse_ops.fsyncdir = fuse_fsyncdir
    fuse_ops.statfs = fuse_statfs
    fuse_ops.setxattr = fuse_setxattr
    fuse_ops.getxattr = fuse_getxattr
    fuse_ops.listxattr = fuse_listxattr
    fuse_ops.removexattr = fuse_removexattr
    fuse_ops.access = fuse_access
    fuse_ops.create = fuse_create

cdef make_fuse_args(list args, fuse_args* f_args):
    cdef char* arg
    cdef int i
    cdef ssize_t size

    args_new = [ 'python-llfuse' ]
    for el in args:
        args_new.append('-o')
        args_new.append(el)
    args = args_new
    
    f_args.argc = <int> len(args)
    if f_args.argc == 0:
        f_args.argv = NULL
        return

    f_args.allocated = 1
    f_args.argv = <char**> stdlib.calloc(f_args.argc, sizeof(char*))

    if f_args.argv is NULL:
        cpython.exc.PyErr_NoMemory()

    try:
        for (i, el) in enumerate(args):
            PyBytes_AsStringAndSize(el, &arg, &size)
            f_args.argv[i] = <char*> stdlib.malloc((size+1)*sizeof(char))

            if f_args.argv[i] is NULL:
                cpython.exc.PyErr_NoMemory()

            string.strncpy(f_args.argv[i], arg, size+1)
    except:
        for i in range(f_args.argc):
            # Freeing a NULL pointer (if this element has not been allocated
            # yet) is fine.
            stdlib.free(f_args.argv[i])
        stdlib.free(f_args.argv)
        raise
    
cdef class Lock:
    '''
    This is the class of lock itself as well as a context manager to
    execute code while the global lock is being held.
    '''

    def __init__(self):
        raise TypeError('You should not instantiate this class, use the '
                        'provided instance instead.')

    def acquire(self):
        '''Acquire global lock'''
        
        cdef int ret
        with nogil:
            ret = acquire()

        if ret == 0:
            return
        elif ret == EDEADLK:
            raise RuntimeError("Global lock cannot be acquired more than once")
        else:
            raise RuntimeError("pthread_lock_mutex returned errorcode %d" % ret)

    def release(self, *a):
        '''Release global lock'''
        
        cdef int ret
        with nogil:
            ret = release()
            
        if ret == 0:
            return
        elif ret == EPERM:
            raise RuntimeError("Global lock can only be released by the holding thread")
        else:
            raise RuntimeError("pthread_unlock_mutex returned errorcode %d" % ret)

    def yield_(self):
        '''Yield global lock to a different thread'''

        cdef int ret1, ret2

        with nogil:
            ret1 = release()
            if ret1 ==  0:
                sched_yield()
                ret2 = acquire()

        if ret1 != 0:
            if ret1 == EPERM:
                raise RuntimeError("Global lock can only be released by the holding thread")
            else:
                raise RuntimeError("pthread_unlock_mutex returned errorcode %d" % ret1)
        elif ret2 != 0:
            raise RuntimeError("pthread_lock_mutex returned errorcode %d" % ret2)

    __enter__ = acquire
    __exit__ = release


cdef class NoLockManager:
    '''Context manager to execute code while the global lock is released'''

    def __init__(self):
        raise TypeError('You should not instantiate this class, use the '
                        'provided instance instead.')

    def __enter__ (self):
        lock.release()
        
    def __exit__(self, *a):
        lock.acquire()

