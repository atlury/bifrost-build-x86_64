From: Linus Torvalds <torvalds@linux-foundation.org>
Date: Tue, 17 Jan 2012 23:21:19 +0000 (-0800)
Subject: proc: clean up and fix /proc/<pid>/mem handling
X-Git-Tag: v3.3-rc1~28
X-Git-Url: https://git.kernel.org/?p=linux%2Fkernel%2Fgit%2Ftorvalds%2Flinux-2.6.git;a=commitdiff_plain;h=e268337dfe26dfc7efd422a804dbb27977a3cccc

proc: clean up and fix /proc/<pid>/mem handling

Jüri Aedla reported that the /proc/<pid>/mem handling really isn't very
robust, and it also doesn't match the permission checking of any of the
other related files.

This changes it to do the permission checks at open time, and instead of
tracking the process, it tracks the VM at the time of the open.  That
simplifies the code a lot, but does mean that if you hold the file
descriptor open over an execve(), you'll continue to read from the _old_
VM.

That is different from our previous behavior, but much simpler.  If
somebody actually finds a load where this matters, we'll need to revert
this commit.

I suspect that nobody will ever notice - because the process mapping
addresses will also have changed as part of the execve.  So you cannot
actually usefully access the fd across a VM change simply because all
the offsets for IO would have changed too.

Reported-by: Jüri Aedla <asd@ut.ee>
Cc: Al Viro <viro@zeniv.linux.org.uk>
Signed-off-by: Linus Torvalds <torvalds@linux-foundation.org>
---

diff --git a/fs/proc/base.c b/fs/proc/base.c
index 5485a53..662ddf2 100644
--- a/fs/proc/base.c
+++ b/fs/proc/base.c
@@ -198,65 +198,7 @@ static int proc_root_link(struct dentry *dentry, struct path *path)
 	return result;
 }
 
-static struct mm_struct *__check_mem_permission(struct task_struct *task)
-{
-	struct mm_struct *mm;
-
-	mm = get_task_mm(task);
-	if (!mm)
-		return ERR_PTR(-EINVAL);
-
-	/*
-	 * A task can always look at itself, in case it chooses
-	 * to use system calls instead of load instructions.
-	 */
-	if (task == current)
-		return mm;
-
-	/*
-	 * If current is actively ptrace'ing, and would also be
-	 * permitted to freshly attach with ptrace now, permit it.
-	 */
-	if (task_is_stopped_or_traced(task)) {
-		int match;
-		rcu_read_lock();
-		match = (ptrace_parent(task) == current);
-		rcu_read_unlock();
-		if (match && ptrace_may_access(task, PTRACE_MODE_ATTACH))
-			return mm;
-	}
-
-	/*
-	 * No one else is allowed.
-	 */
-	mmput(mm);
-	return ERR_PTR(-EPERM);
-}
-
-/*
- * If current may access user memory in @task return a reference to the
- * corresponding mm, otherwise ERR_PTR.
- */
-static struct mm_struct *check_mem_permission(struct task_struct *task)
-{
-	struct mm_struct *mm;
-	int err;
-
-	/*
-	 * Avoid racing if task exec's as we might get a new mm but validate
-	 * against old credentials.
-	 */
-	err = mutex_lock_killable(&task->signal->cred_guard_mutex);
-	if (err)
-		return ERR_PTR(err);
-
-	mm = __check_mem_permission(task);
-	mutex_unlock(&task->signal->cred_guard_mutex);
-
-	return mm;
-}
-
-struct mm_struct *mm_for_maps(struct task_struct *task)
+static struct mm_struct *mm_access(struct task_struct *task, unsigned int mode)
 {
 	struct mm_struct *mm;
 	int err;
@@ -267,7 +209,7 @@ struct mm_struct *mm_for_maps(struct task_struct *task)
 
 	mm = get_task_mm(task);
 	if (mm && mm != current->mm &&
-			!ptrace_may_access(task, PTRACE_MODE_READ)) {
+			!ptrace_may_access(task, mode)) {
 		mmput(mm);
 		mm = ERR_PTR(-EACCES);
 	}
@@ -276,6 +218,11 @@ struct mm_struct *mm_for_maps(struct task_struct *task)
 	return mm;
 }
 
+struct mm_struct *mm_for_maps(struct task_struct *task)
+{
+	return mm_access(task, PTRACE_MODE_READ);
+}
+
 static int proc_pid_cmdline(struct task_struct *task, char * buffer)
 {
 	int res = 0;
@@ -752,38 +699,39 @@ static const struct file_operations proc_single_file_operations = {
 
 static int mem_open(struct inode* inode, struct file* file)
 {
-	file->private_data = (void*)((long)current->self_exec_id);
+	struct task_struct *task = get_proc_task(file->f_path.dentry->d_inode);
+	struct mm_struct *mm;
+
+	if (!task)
+		return -ESRCH;
+
+	mm = mm_access(task, PTRACE_MODE_ATTACH);
+	put_task_struct(task);
+
+	if (IS_ERR(mm))
+		return PTR_ERR(mm);
+
 	/* OK to pass negative loff_t, we can catch out-of-range */
 	file->f_mode |= FMODE_UNSIGNED_OFFSET;
+	file->private_data = mm;
+
 	return 0;
 }
 
 static ssize_t mem_read(struct file * file, char __user * buf,
 			size_t count, loff_t *ppos)
 {
-	struct task_struct *task = get_proc_task(file->f_path.dentry->d_inode);
+	int ret;
 	char *page;
 	unsigned long src = *ppos;
-	int ret = -ESRCH;
-	struct mm_struct *mm;
+	struct mm_struct *mm = file->private_data;
 
-	if (!task)
-		goto out_no_task;
+	if (!mm)
+		return 0;
 
-	ret = -ENOMEM;
 	page = (char *)__get_free_page(GFP_TEMPORARY);
 	if (!page)
-		goto out;
-
-	mm = check_mem_permission(task);
-	ret = PTR_ERR(mm);
-	if (IS_ERR(mm))
-		goto out_free;
-
-	ret = -EIO;
- 
-	if (file->private_data != (void*)((long)current->self_exec_id))
-		goto out_put;
+		return -ENOMEM;
 
 	ret = 0;
  
@@ -810,13 +758,7 @@ static ssize_t mem_read(struct file * file, char __user * buf,
 	}
 	*ppos = src;
 
-out_put:
-	mmput(mm);
-out_free:
 	free_page((unsigned long) page);
-out:
-	put_task_struct(task);
-out_no_task:
 	return ret;
 }
 
@@ -825,27 +767,15 @@ static ssize_t mem_write(struct file * file, const char __user *buf,
 {
 	int copied;
 	char *page;
-	struct task_struct *task = get_proc_task(file->f_path.dentry->d_inode);
 	unsigned long dst = *ppos;
-	struct mm_struct *mm;
+	struct mm_struct *mm = file->private_data;
 
-	copied = -ESRCH;
-	if (!task)
-		goto out_no_task;
+	if (!mm)
+		return 0;
 
-	copied = -ENOMEM;
 	page = (char *)__get_free_page(GFP_TEMPORARY);
 	if (!page)
-		goto out_task;
-
-	mm = check_mem_permission(task);
-	copied = PTR_ERR(mm);
-	if (IS_ERR(mm))
-		goto out_free;
-
-	copied = -EIO;
-	if (file->private_data != (void *)((long)current->self_exec_id))
-		goto out_mm;
+		return -ENOMEM;
 
 	copied = 0;
 	while (count > 0) {
@@ -869,13 +799,7 @@ static ssize_t mem_write(struct file * file, const char __user *buf,
 	}
 	*ppos = dst;
 
-out_mm:
-	mmput(mm);
-out_free:
 	free_page((unsigned long) page);
-out_task:
-	put_task_struct(task);
-out_no_task:
 	return copied;
 }
 
@@ -895,11 +819,20 @@ loff_t mem_lseek(struct file *file, loff_t offset, int orig)
 	return file->f_pos;
 }
 
+static int mem_release(struct inode *inode, struct file *file)
+{
+	struct mm_struct *mm = file->private_data;
+
+	mmput(mm);
+	return 0;
+}
+
 static const struct file_operations proc_mem_operations = {
 	.llseek		= mem_lseek,
 	.read		= mem_read,
 	.write		= mem_write,
 	.open		= mem_open,
+	.release	= mem_release,
 };
 
 static ssize_t environ_read(struct file *file, char __user *buf,
