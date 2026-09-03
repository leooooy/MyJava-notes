# 配置 SSH 密钥



```c
git config --global user.name"自己账户的名字，建议就是github上的账户名，这样好记"
git config --global user.email"自己账户的邮箱地址，建议也是用GitHub上的那个"

git config --global -l //这条命令是用来查看上面的信息是否之前已经被输入了，自己检查
```

**SSH登陆的原理**

**1.什么是SSH**
SSH是一种网络协议，用于计算机之间的加密通信。

**2.公钥Public Key与私钥Private Key**
SSH Key
SSH需要生成公钥Public Key和[私钥](https://so.csdn.net/so/search?q=私钥&spm=1001.2101.3001.7020)Private Key, 常用的是使用RSA算法生成id_rsa.pub和id_rsa。
公钥Public Key(id_rsa.pub)是可以暴露在网络传输上的，是不安全的。而私钥Private Key(id_rsa)是不可暴露的，只能存在客户端本机上。

所以公钥Public Key(id_rsa.pub)的权限是644，而私钥Private Key(id_rsa)的权限只能是600。如果权限不对，SSH会认为公钥Public Key(id_rsa.pub)和私钥Private Key(id_rsa)是不可靠的，就无法正常使用SSH登陆了。

同时在服务端会有一个~/.ssh/authorized_keys文件，里面存放了多个客户端的公钥Public Key(id_rsa.pub)，就表示拥有这些Public Key的客户端就可以通过SSH登陆服务端。

**3.SSH公钥登陆过程**
客户端发出公钥登陆的请求(ssh user@host)
服务端返回一段随机字符串
客户端用私钥Private Key(id_rsa)加密这个字符串，再发送回服务端
服务端用~/.ssh/authorized_keys里面存储的公钥Public Key去解密收到的字符串。如果成功，就表明这个客户端是可信的，客户端就可以成功登陆

由此可见，只要多台电脑上的的公钥Public Key(id_rsa.pub)和私钥Private Key(id_rsa)是一样的，对于服务端来说着其实就是同一个客户端。所以可以通过复制公钥Public Key(id_rsa.pub)和私钥Private Key(id_rsa)到多台电脑来实现共享登陆。
这里也需要强调的是，一定要确保公钥Public Key(id_rsa.pub)和私钥Private Key(id_rsa)的安全，不要随意乱扔，乱扔它会污染环境，砸到小朋友怎么办？就算砸不到小朋友砸到花花草草也不好嘛！





先拷贝原始的ssh key，没有的话就生成一个（参考附录）
2、将拷贝的ssh key复制到另一台电脑的用户目录下（linux用户目录：cd ~进入；Windows：在C:\Users\admin中；目录名可能会有一点区别）
3、重新文件赋予权限

cd ~/.ssh
chmod 600 id_rsa
chmod 644 id_rsa.pub
1
2
3
4、用SSH方式clone一个仓库的代码测试（不要用HTTPS）

附录： 生成ssh key
1、ssh-keygen -t rsa -C “youremail@example.com”，把邮件地址换成你自己的邮件地址，然后一直按回车，使用默认值即可。
2、此时应该可以在用户主目录里找到.ssh目录，里面有id_rsa和id_rsa.pub两个文件，这两个就是SSH Key的秘钥对，id_rsa是私钥，不能泄露出去，id_rsa.pub是公钥，可以告诉任何人。



```shell
ssh-keygen -t rsa -C "<您的邮箱>"
```







----

Codeup 支持的 SSH 加密算法类型如下所示：

| 算法类型             | 公钥           | 私钥       |
| -------------------- | -------------- | ---------- |
| **ED25519 （推荐**） | id_ed25519.pub | id_ed25519 |
| RSA （不推荐）       | id_rsa.pub     | id_rsa     |

## 步骤一：查看已存在的 SSH 密钥

在生成新的 SSH 密钥前，请先确认是否需要使用本地已生成的SSH密钥，SSH 密钥对一般存放在本地用户的根目录下。

Linux、Mac 请直接使用以下命令查看已存在的公钥，Windows 用户在 [WSL](https://docs.microsoft.com/en-us/windows/wsl/install)（需要 windows10 或以上）或 [Git Bash](https://gitforwindows.org/)下使用以下命令查看已生成公钥：

**ED25519 算法**

```plaintext
cat ~/.ssh/id_ed25519.pub
```

如果返回一长串以 ssh-ed25519 或 ssh-rsa 开头的字符串, 说明已存在本地公钥，你可以跳过步骤二**生成 SSH 密钥**，直接操作步骤三。



注释会出现在`.pub`文件中，一般可使用邮箱作为注释内容。

- 基于`ED25519`算法，生成密钥对命令如下：

```plaintext
ssh-keygen -t ed25519 -C "<注释内容>"
```

1. **点击回车，**选择 SSH 密钥生成路径。

- 以 ED25519 算法为例，默认路径如下：

```plaintext
Generating public/private ed25519 key pair.
Enter file in which to save the key (/home/user/.ssh/id_ed25519):
```

密钥默认生成路径：`/home/user/.ssh/id_ed25519`，公钥与之对应为：`/home/user/.ssh/id_ed25519.pub`。

1. 设置一个密钥[口令](https://www.ssh.com/academy/ssh/passphrase)。

```plaintext
Enter passphrase (empty for no passphrase):
Enter same passphrase again:
```

口令默认为空，你可以选择使用口令保护私钥文件。如果你不想在每次使用 SSH 协议访问仓库时，都要输入用于保护私钥文件的口令，可以在创建密钥时，输入空口令。

1. 点击回车，完成密钥对创建。



## 步骤四：在 Codeup 上设置公钥

1. 登录云效 [Codeup 页面](https://codeup.aliyun.com/)，在页面右上角选择个人设置>SSH 公钥。
2. 添加生成的 SSH 公钥信息。

- SSH 公钥内容。

**说明** 

请完整拷贝本机中公钥从 ssh- 开始直到邮箱为止的内容。

- 公钥标题：支持自定义公钥名称，用于区分管理。
- 作用范围：设置公钥的作用范围，包括读写或是只读，若设置为只读，该公钥只能用于拉取代码，不允许推送。
- 过期时间：设置公钥过期时间，到期后公钥将自动失效，不可使用。







# [SSH](https://www.cnblogs.com/ayseeing/p/4646214.html)

### 什么是SSH

SSH是一种网络协议，用于计算机之间的加密通信。

 

### 公钥Public Key与私钥Private Key

SSH需要生成公钥Public Key和私钥Private Key, 常用的是使用RSA算法生成`id_rsa.pub`和`id_rsa`。 公钥Public Key(`id_rsa.pub`)是可以暴露在网络传输上的，是不安全的。而私钥Private Key(`id_rsa`)是不可暴露的，只能存在客户端本机上。 所以公钥Public Key(`id_rsa.pub`)的权限是644，而私钥Private Key(`id_rsa`)的权限只能是600。如果权限不对，SSH会认为公钥Public Key(`id_rsa.pub`)和私钥Private Key(`id_rsa`)是不可靠的，就无法正常使用SSH登陆了。

同时在服务端会有一个`~/.ssh/authorized_keys`文件，里面存放了多个客户端的公钥Public Key(`id_rsa.pub`)，就表示拥有这些Public Key的客户端就可以通过SSH登陆服务端。

 

### SSH公钥登陆过程

1. 客户端发出公钥登陆的请求(`ssh user@host`)
2. 服务端返回一段随机字符串
3. 客户端用私钥Private Key(`id_rsa`)加密这个字符串，再发送回服务端
4. 服务端用`~/.ssh/authorized_keys`里面存储的公钥Public Key去解密收到的字符串。如果成功，就表明这个客户端是可信的，客户端就可以成功登陆

由此可见，只要多台电脑上的的公钥Public Key(`id_rsa.pub`)和私钥Private Key(`id_rsa`)是一样的，对于服务端来说着其实就是同一个客户端。所以可以通过复制公钥Public Key(`id_rsa.pub`)和私钥Private Key(`id_rsa`)到多台电脑来实现共享登陆。