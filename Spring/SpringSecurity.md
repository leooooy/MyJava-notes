# Spring Security

> 安全面试必考。这道题的"段位差"在三点：
> ① 能不能讲清 **Filter 链 15 个过滤器** 的协作（不是只说"过滤器多"）
> ② 能不能讲清 **认证 Authentication / 授权 Authorization** 各自的核心抽象
> ③ 能不能讲清 **Session vs JWT vs OAuth2** 的取舍和落地方案
> 答得清这三块就是高级。

---

## 一、Spring Security 解决什么

**两件事**：
1. **认证（Authentication）**：你是谁——证明用户身份
2. **授权（Authorization）**：你能干啥——确认是否有权限访问资源

```
请求进来
  │
  ▼
[认证] 你是张三？拿出登录态/JWT/API Key
  │
  ▼
[授权] 张三能访问 /admin/* 吗？检查角色和权限
  │
  ▼
执行业务
```

**为什么不自己写**：
- 认证授权的细节多——会话固定攻击、CSRF、密码加密、记住我、并发会话、密码重置……
- 一个安全漏洞 = 公司事故
- Spring Security 经过大规模生产验证

---

## 二、整体架构

```
HTTP 请求
   │
   ▼
┌───────────────── Servlet 容器 (Tomcat) ──────────────────────┐
│                                                                │
│  DelegatingFilterProxy ────→ 委托给 Spring 容器                │
│        │                                                       │
│        ▼                                                       │
│  FilterChainProxy ── Spring Security 总入口                    │
│        │                                                       │
│        ▼                                                       │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │  SecurityFilterChain (15 个过滤器，按顺序)               │ │
│  │                                                            │ │
│  │  1. ChannelProcessingFilter      要求 HTTPS               │ │
│  │  2. WebAsyncManagerIntegrationFilter                       │ │
│  │  3. SecurityContextHolderFilter  ★ 加载 SecurityContext   │ │
│  │  4. HeaderWriterFilter           安全响应头（X-Frame...）  │ │
│  │  5. CorsFilter                   CORS                      │ │
│  │  6. CsrfFilter                   CSRF token 校验           │ │
│  │  7. LogoutFilter                 处理 /logout              │ │
│  │  8. UsernamePasswordAuthFilter ★ 处理 /login (用户名密码)  │ │
│  │  9. DefaultLoginPageFilter       默认登录页                │ │
│  │ 10. BasicAuthenticationFilter    HTTP Basic               │ │
│  │ 11. RequestCacheAwareFilter                                │ │
│  │ 12. SecurityContextHolderAwareRequestFilter                │ │
│  │ 13. AnonymousAuthenticationFilter ★ 给未登录加匿名身份    │ │
│  │ 14. ExceptionTranslationFilter ★ 处理 401/403             │ │
│  │ 15. FilterSecurityInterceptor ★ 授权决策（v6 改 Authorize）│ │
│  └──────────────────────────────────────────────────────────┘ │
│        │                                                       │
│        ▼                                                       │
│  DispatcherServlet → Controller                                │
└────────────────────────────────────────────────────────────────┘
```

**关键设计**：所有安全逻辑都在 **过滤器链**——业务代码（Controller / Service）几乎无感知。

---

## 三、核心概念

### 3.1 `Authentication`：身份信息

```java
public interface Authentication extends Principal, Serializable {
    Collection<? extends GrantedAuthority> getAuthorities();   // 角色 / 权限
    Object getCredentials();                                    // 凭证（密码 / token）
    Object getDetails();                                        // 附加信息（IP / Session ID）
    Object getPrincipal();                                      // 主体（User 对象）
    boolean isAuthenticated();                                  // 是否已认证
    String getName();                                           // 用户名
}
```

常见实现：
- `UsernamePasswordAuthenticationToken`：用户名密码认证
- `JwtAuthenticationToken`：JWT 认证
- `AnonymousAuthenticationToken`：匿名

### 3.2 `SecurityContext` + `SecurityContextHolder`

**当前线程的认证上下文**——通过 ThreadLocal 持有：

```java
SecurityContext ctx = SecurityContextHolder.getContext();
Authentication auth = ctx.getAuthentication();
String username = auth.getName();
```

业务代码任何地方都能拿到当前用户。Controller 里也能直接注入：

```java
@GetMapping("/me")
public User me(Authentication auth) {
    return userDao.findByName(auth.getName());
}
```

### 3.3 `AuthenticationManager` + `AuthenticationProvider`

```
AuthenticationManager（接口）
    │
    └─ ProviderManager（默认实现）
        │
        └─ List<AuthenticationProvider>     ← 责任链
            ├─ DaoAuthenticationProvider     基于 UserDetailsService（最常用）
            ├─ JwtAuthenticationProvider
            ├─ LdapAuthenticationProvider
            └─ ...
```

每个 Provider 处理一种认证方式，按顺序尝试。

### 3.4 `UserDetailsService`：用户数据来源

```java
public interface UserDetailsService {
    UserDetails loadUserByUsername(String username) throws UsernameNotFoundException;
}

public interface UserDetails {
    Collection<? extends GrantedAuthority> getAuthorities();
    String getPassword();
    String getUsername();
    boolean isAccountNonExpired();
    boolean isAccountNonLocked();
    boolean isCredentialsNonExpired();
    boolean isEnabled();
}
```

业务实现：

```java
@Service
public class MyUserDetailsService implements UserDetailsService {
    @Resource private UserDao userDao;
    
    @Override
    public UserDetails loadUserByUsername(String username) {
        User u = userDao.findByName(username);
        if (u == null) throw new UsernameNotFoundException(username);
        return User.builder()
            .username(u.getName())
            .password(u.getPasswordHash())
            .authorities(u.getRoles().stream().map(r -> "ROLE_" + r).toArray(String[]::new))
            .accountLocked(u.isLocked())
            .build();
    }
}
```

### 3.5 `PasswordEncoder`：密码加密

**永远不要明文存密码**。Spring Security 提供：

| Encoder | 算法 | 现状 |
| --- | --- | --- |
| `BCryptPasswordEncoder` | BCrypt（带盐） | **生产推荐** |
| `Argon2PasswordEncoder` | Argon2 | **更新选择**（抗 GPU 破解） |
| `Pbkdf2PasswordEncoder` | PBKDF2 | OK |
| `NoOpPasswordEncoder` | 明文 | **测试也别用** |
| `MessageDigestPasswordEncoder` | MD5 / SHA-1 | **已过时**（彩虹表攻击） |

```java
@Bean
public PasswordEncoder passwordEncoder() {
    return new BCryptPasswordEncoder();
}

// 注册时
String hash = encoder.encode("plain-password");      // 写入 DB
// 登录时由 DaoAuthenticationProvider 自动校验
```

> **追问**：BCrypt 为什么安全？① 自带盐（每次结果不同）；② 计算慢（强制每次校验耗时 100ms+，破解者也慢）；③ cost 因子可调（CPU 升级时把 cost 调高）。

---

## 四、Spring Security 6 配置（lambda DSL）

Spring Security 5.7+ 弃用 `WebSecurityConfigurerAdapter`，改用 lambda DSL：

```java
@Configuration
@EnableWebSecurity
@EnableMethodSecurity                           // 启用 @PreAuthorize 等方法注解
public class SecurityConfig {
    
    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        return http
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/login", "/register", "/public/**").permitAll()
                .requestMatchers("/admin/**").hasRole("ADMIN")
                .requestMatchers(HttpMethod.GET, "/api/**").hasAuthority("READ")
                .anyRequest().authenticated()
            )
            .formLogin(form -> form
                .loginPage("/login")
                .defaultSuccessUrl("/home")
                .failureUrl("/login?error")
                .permitAll()
            )
            .logout(logout -> logout
                .logoutUrl("/logout")
                .logoutSuccessUrl("/login")
            )
            .csrf(csrf -> csrf.disable())                // REST API 无状态，关掉 CSRF（看场景）
            .sessionManagement(sm -> sm
                .sessionCreationPolicy(SessionCreationPolicy.STATELESS)  // JWT 场景
            )
            .build();
    }
    
    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }
    
    @Bean
    public AuthenticationManager authenticationManager(AuthenticationConfiguration config) throws Exception {
        return config.getAuthenticationManager();
    }
}
```

---

## 五、方法级授权

### 5.1 4 种注解

```java
@PreAuthorize("hasRole('ADMIN')")                              // ★ 最常用
public void adminOnly() { ... }

@PreAuthorize("hasAuthority('USER_DELETE') and #userId != authentication.principal.id")
public void deleteUser(Long userId) { ... }

@PostAuthorize("returnObject.userId == authentication.principal.id")
public Order getOrder(Long id) { ... }                          // 调用后校验返回对象

@Secured({"ROLE_ADMIN", "ROLE_MANAGER"})                       // 简单角色校验（旧）
public void manage() { ... }

@RolesAllowed("ADMIN")                                         // JSR-250
public void doSth() { ... }
```

### 5.2 SpEL 上下文

可用变量：
- `authentication` —— 当前 `Authentication`
- `principal` —— 主体（`UserDetails`）
- `#参数名` —— 方法参数
- `returnObject` —— 返回值（仅 `@PostAuthorize`）

常用方法：
- `hasRole('X')` —— 等价于 `hasAuthority('ROLE_X')`
- `hasAuthority('X')`
- `hasAnyRole('X','Y')`
- `permitAll()` / `denyAll()`
- `isAuthenticated()` / `isAnonymous()`

---

## 六、JWT 集成（无状态认证主流方案）

### 6.1 为什么 JWT

传统 Session：
- ❌ 需要服务端存 Session（Redis / DB）
- ❌ 跨域、移动端、多租户支持差
- ❌ 服务端故障 / 重启导致登录态丢失

JWT：
- ✅ 无状态——服务端不存
- ✅ 跨域友好（放在 Header 里）
- ✅ 包含用户信息（避免每次查 DB）
- ❌ 不能主动失效（除非维护黑名单——又变有状态）

### 6.2 JWT 三段结构

```
header.payload.signature

eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyMSIsInJvbGUiOiJBRE1JTiJ9.signature
└──── header ────┘└──────────── payload ──────────────┘└── 签名 ─┘
```

- **header**：算法（HS256 / RS256）
- **payload**：claims（sub / exp / iat / 自定义）
- **signature**：用密钥 + 算法对前两段签名，**防篡改**

> **重要**：payload **只是 base64 编码、不是加密**——任何人能解出来。**别放敏感信息**。

### 6.3 JWT 过滤器

```java
public class JwtAuthFilter extends OncePerRequestFilter {
    @Resource private JwtUtils jwtUtils;
    @Resource private UserDetailsService userDetailsService;
    
    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse resp, FilterChain chain) {
        String header = req.getHeader("Authorization");
        if (header != null && header.startsWith("Bearer ")) {
            String token = header.substring(7);
            try {
                String username = jwtUtils.getUsername(token);
                if (SecurityContextHolder.getContext().getAuthentication() == null) {
                    UserDetails user = userDetailsService.loadUserByUsername(username);
                    if (jwtUtils.validate(token, user)) {
                        UsernamePasswordAuthenticationToken auth = new UsernamePasswordAuthenticationToken(
                                user, null, user.getAuthorities());
                        auth.setDetails(new WebAuthenticationDetailsSource().buildDetails(req));
                        SecurityContextHolder.getContext().setAuthentication(auth);
                    }
                }
            } catch (Exception e) {
                log.warn("jwt invalid", e);
            }
        }
        chain.doFilter(req, resp);
    }
}

// 注册到链上
@Bean
public SecurityFilterChain chain(HttpSecurity http, JwtAuthFilter jwtFilter) throws Exception {
    return http
        ...
        .addFilterBefore(jwtFilter, UsernamePasswordAuthenticationFilter.class)
        .build();
}
```

### 6.4 双 token 设计（生产推荐）

```
登录成功
└─ 颁发 access_token（1 小时）+ refresh_token（30 天）

访问 API
└─ 带 access_token → 校验通过 → 放行
   ↓ 失败 401
   ↓ 客户端自动用 refresh_token 换新的 access_token
   └─ 失败（refresh 也过期）→ 重新登录

退出登录
└─ refresh_token 加入黑名单 / Redis（吊销）
```

**好处**：access_token 短，被盗了影响小；refresh_token 长，不需要频繁登录；可以主动吊销。

---

## 七、OAuth2 / OIDC

### 7.1 什么时候用

- 第三方登录（微信 / GitHub 登录到我的网站）
- 企业 SSO（一次登录访问 N 个内部系统）
- 开放平台（外部应用代表用户访问 API）

### 7.2 OAuth2 4 种授权模式

| 模式 | 适用 | 流程 |
| --- | --- | --- |
| **授权码**（Authorization Code）★ | Web 应用、有后端 | 三方 → 授权服务器 → 回调码 → 后端换 token |
| **隐式**（Implicit） | 纯前端 SPA（已不推荐） | 直接返回 token |
| **密码**（Password） | 自家信任客户端 | 用户名密码换 token（不推荐外部） |
| **客户端凭证**（Client Credentials） | 服务间调用 | 用 client_id + secret 换 token |

> **生产**：90% 用授权码模式；服务间调用用客户端凭证。

### 7.3 Spring Security OAuth2 Client

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-oauth2-client</artifactId>
</dependency>
```

```yaml
spring:
  security:
    oauth2:
      client:
        registration:
          github:
            client-id: ${GITHUB_CLIENT_ID}
            client-secret: ${GITHUB_CLIENT_SECRET}
            scope: read:user
```

启动后自动暴露 `/oauth2/authorization/github` 触发跳转。

---

## 八、CSRF 防御

### 8.1 什么是 CSRF

攻击者诱导已登录用户点击恶意链接：

```html
<!-- 恶意网站 -->
<img src="https://bank.com/transfer?to=attacker&amount=10000" />
```

用户已登录 bank.com，浏览器自动带 Cookie——攻击者借用户身份转账。

### 8.2 Spring Security 默认开启

**Spring Security 默认开 CSRF**——每个表单请求要带 `_csrf` token，token 不对就 403。

### 8.3 REST API 怎么办

REST API 用 JWT / Token 认证（不依赖 Cookie）—— **CSRF 攻击不成立**（攻击者拿不到 JWT 放 Header）。所以可以关掉：

```java
http.csrf(csrf -> csrf.disable())
```

> **关 CSRF 的前提**：① 认证不依赖 Cookie；② 或者 SameSite Cookie 配 Strict / Lax。Cookie 认证场景**别关 CSRF**。

---

## 九、生产踩坑

### 坑 1：忘记 `@EnableMethodSecurity`，`@PreAuthorize` 不生效

```java
@Service public class A {
    @PreAuthorize("hasRole('ADMIN')")     // ❌ 没启用方法级安全，注解形同虚设
    public void admin() { ... }
}
```

**修法**：配置类加 `@EnableMethodSecurity`（Spring Security 6+；旧版 `@EnableGlobalMethodSecurity(prePostEnabled = true)`）。

### 坑 2：CORS 和 CSRF 配置顺序错

CORS 必须在 CSRF 前生效——浏览器预检（OPTIONS）不带 CSRF token，会被 CSRF 拦掉。
**修法**：CORS Filter 高优先级、CSRF 配 `csrf.ignoringRequestMatchers("/api/**")` 跳过 API。

### 坑 3：JWT 密钥泄漏

密钥写在 application.yml 里 → 提交 Git → 公开仓库 → 攻击者用密钥伪造任意用户的 JWT。
**修法**：① 用环境变量；② RS256 非对称签名（公钥可暴露，私钥严格保密）；③ 定期 rotate 密钥。

### 坑 4：JWT 没法主动失效

用户改密 / 退出登录后，旧 JWT 仍然有效到过期。
**修法**：
- 维护黑名单（Redis）—— 但变有状态了
- 用短 TTL access_token + refresh_token
- token 里放版本号，DB 存当前版本号，校验时比对（每次请求查 DB / Redis）

### 坑 5：密码 BCrypt 但慢导致登录卡

BCrypt 默认 cost=10，每次校验约 100ms。同时 100 个用户登录 → 100 个线程都在算 → CPU 100%。
**修法**：① 降低 cost（不推荐）；② 增加 Tomcat 线程池；③ 限流 + 验证码防暴力破解。

### 坑 6：Session 固定攻击

用户未登录时拿到 SessionID = "abc"，登录后 SessionID 还是 "abc" → 攻击者预先获取 SessionID 诱导用户用它登录。
**修法**：Spring Security 默认会 `migrateSession`（登录后换新 SessionID）—— **别手动关掉**。

### 坑 7：并发会话不限制

用户在 PC 登录后，手机又登录 → 两边都能用 → 共享账号 / 防盗号失效。
**修法**：

```java
http.sessionManagement(sm -> sm
    .maximumSessions(1)
    .maxSessionsPreventsLogin(false)    // false：新登录踢旧登录；true：新登录被拒
);
```

### 坑 8：`@PreAuthorize` 里 SpEL 写错

```java
@PreAuthorize("hasRole('admin')")    // ❌ 大小写敏感，应该是 'ADMIN'
```

或者写错变量名 `#userid` vs `#userId`——**SpEL 错误不会编译期报错**，运行时静默不通过授权。
**修法**：写完单测；用集成测试覆盖授权逻辑。

---

## 十、面试高频追问

**Q1：Spring Security 的核心架构？**
A：**过滤器链 + 责任链 Provider**。请求通过 `DelegatingFilterProxy` 转到 `FilterChainProxy`，按顺序经过 15 个 SecurityFilter。每个 filter 负责一个关注点：CSRF、CORS、登录处理（`UsernamePasswordAuthenticationFilter`）、JWT 解析、授权决策（`AuthorizationFilter`，v6）。最后到 DispatcherServlet。

**Q2：认证流程？**
A：① `UsernamePasswordAuthenticationFilter` 拿到用户名密码；② 构造 `UsernamePasswordAuthenticationToken`；③ 交给 `AuthenticationManager`（默认 `ProviderManager`）；④ 遍历 `AuthenticationProvider`（默认 `DaoAuthenticationProvider`）；⑤ Provider 调 `UserDetailsService.loadUserByUsername` 拿用户、`PasswordEncoder.matches` 校验密码；⑥ 成功后把已认证的 `Authentication` 放进 `SecurityContextHolder`。

**Q3：授权流程？**
A：v6 用 `AuthorizationFilter`（旧 `FilterSecurityInterceptor`）。① 提取当前 `Authentication`；② 用 `AuthorizationManager` 判断当前用户是否有权访问目标资源；③ 不通过抛 `AccessDeniedException`，被 `ExceptionTranslationFilter` 捕获返 403。方法级用 `@PreAuthorize` + AOP 拦截。

**Q4：`hasRole` 和 `hasAuthority` 区别？**
A：`hasRole('X')` 等价于 `hasAuthority('ROLE_X')`——会自动加 `ROLE_` 前缀。所以数据库存的角色字段应该有 `ROLE_` 前缀（`ROLE_ADMIN`），用 `hasRole('ADMIN')`；如果是细粒度权限直接用 `hasAuthority('USER_DELETE')`。

**Q5：BCrypt 为什么比 MD5 安全？**
A：① 自带盐——每次结果不同，彩虹表无效；② 慢——故意每次校验 100ms+，让破解者也慢；③ cost 因子可调——CPU 升级时把 cost 调高保持安全裕度。MD5 速度太快（每秒数十亿）+ 没盐，已经被彩虹表完全破解。

**Q6：Session 和 JWT 怎么选？**
A：
- **Session**：服务端存状态、可主动失效、CSRF 风险——传统 Web、单体应用合适
- **JWT**：无状态、跨域好、扩展性好、不能主动失效——REST API、微服务、移动端合适
- **生产折中**：双 token（短 access + 长 refresh）+ Redis 维护吊销列表

**Q7：CSRF 怎么防？**
A：Spring Security 默认开 CSRF——表单要带 `_csrf` token。REST API 用 JWT 时可以关，因为认证不依赖 Cookie。**Cookie 认证一定不要关 CSRF**。补充：SameSite Cookie 也是有效防御。

**Q8：OAuth2 4 种授权模式选哪个？**
A：① **授权码**——Web 应用 + 有后端，最安全（90% 场景）；② 客户端凭证——服务间调用；③ 隐式——纯前端 SPA（已不推荐，OAuth2.1 已废）；④ 密码——自家应用信任客户端（不推荐外部）。

**Q9：怎么实现"踢人下线"？**
A：① **Session 模式**：删除该用户的所有 Session；② **JWT 模式**：把 token 加入 Redis 黑名单（每次校验时查），或在用户表里维护 token 版本号（改密时 +1，旧 token 失效）。

**Q10：方法级安全注解失效怎么办？**
A：① 检查 `@EnableMethodSecurity` 是否加；② 是否 self-invocation（this 自调用）—— AOP 失效；③ 方法是否 public；④ SpEL 表达式是否写对（hasRole 大小写、变量名）；⑤ bean 是否纳入 Spring 管理。

---

## 十一、答题模板（60 秒）

> Spring Security 解决两件事：**认证（你是谁）+ 授权（你能干啥）**。
>
> **架构**：过滤器链 + 责任链 Provider。`DelegatingFilterProxy → FilterChainProxy →` 15 个 SecurityFilter（按顺序：CORS → CSRF → 登录 → JWT 解析 → 授权 →...）。
>
> **认证流程**：`UsernamePasswordAuthenticationFilter` 拿凭证 → `AuthenticationManager (ProviderManager)` → `AuthenticationProvider (DaoAuthenticationProvider)` → `UserDetailsService.loadUserByUsername` + `PasswordEncoder.matches` → 成功后写 `SecurityContextHolder`。
>
> **授权**：URL 级 `authorizeHttpRequests` + `requestMatchers("...").hasRole("...")`；方法级 `@EnableMethodSecurity` + `@PreAuthorize("hasRole('ADMIN')")`。
>
> **密码**：永远不明文，用 **BCryptPasswordEncoder**（自带盐 + 慢哈希 + cost 可调），或 Argon2。
>
> **REST API 主流方案**：JWT 无状态认证。**双 token 设计**：access_token 短 TTL（1h）+ refresh_token 长 TTL（30d），refresh 放 Redis 黑名单实现主动吊销。注意 **JWT payload 是 base64 不是加密**——别放敏感信息；密钥用环境变量或 RS256 非对称签名。
>
> **OAuth2 / OIDC** 用于第三方登录、SSO、开放平台——授权码模式是绝对主流（90% 场景）。
>
> **生产高频坑**：① 忘加 `@EnableMethodSecurity`；② CORS / CSRF 顺序错；③ JWT 密钥泄漏 / 没法主动失效（用黑名单或版本号）；④ 方法级安全 SpEL 写错静默不生效；⑤ 并发会话没限制。

---

## 十二、相关文档

- 前置：[AOP.md](AOP.md) — 方法级安全 `@PreAuthorize` 是 AOP
- 前置：[SpringMVC.md](SpringMVC.md) — Filter 在 Spring MVC 之前
- 配套：[SpringCloudGateway.md](SpringCloudGateway.md) — 微服务统一鉴权放网关
- 配套：[../Distributed/](../Distributed/README.md) — 分布式 Session / 单点登录
