# Relayed Match 对接流程：匹配微服务 → 客户端进房

适用于「轻度休闲联机」：服务器只做房间 + 消息转发，不做权威逻辑，便于热更新与扩容。

---

## 一、Relayed Match 在 nakama-plus 中的约定

- **Match ID 格式**：`{uuid}.`（注意末尾有一个点）
  - 有「节点」的是权威房：`{uuid}.{nodeName}`，无节点即 Relayed：`{uuid}.`
- **创建房间**：客户端发 `MatchCreate`，可选传 `name`：
  - 传 `name`：`matchID = UUID5(namespaceDNS, name)`，**同一 name 即同一房间**，其他人用同一 match_id 可加入
  - 不传：随机 UUID，仅创建者自己进房（别人无法用 ID 加入）
- **加入房间**：客户端发 `MatchJoin`，带 `match_id`（即 `uuid.`）
- **发局内消息**：`MatchDataSend`，服务器按房间转发给同 stream 内其他 presence，不经过 MatchLoop

因此：**匹配服务只需生成一个全局唯一的「房间名」room_name，客户端用同一 room_name 推导出同一 match_id，一人 Create、其余 Join 即可。**

---

## 二、Match ID 与 room_name 的换算（必须一致）

服务端（Go）与客户端（Unity/C# 等）必须用**相同算法**，否则无法进同一房。

```go
// Go（匹配微服务 / 后端）
import "github.com/gofrs/uuid/v5"

const NakamaRelayedMatchNamespaceDNS = "6ba7b810-9dad-11d1-80b4-00c04fd430c8" // uuid.NamespaceDNS

func RoomNameToMatchID(roomName string) string {
    ns := uuid.Must(uuid.FromString(NakamaRelayedMatchNamespaceDNS))
    id := uuid.NewV5(ns, roomName)
    return id.String() + "."
}
```

```csharp
// C#（Unity 等，需与 Go 同 namespace）
using System;
using UnityEngine;

public static class RelayedMatchId
{
    public static readonly Guid NamespaceDNS = new Guid("6ba7b810-9dad-11d1-80b4-00c04fd430c8");

    public static string RoomNameToMatchId(string roomName)
    {
        var bytes = NamespaceDNS.ToByteArray();
        var nameBytes = System.Text.Encoding.UTF8.GetBytes(roomName);
        var hash = new byte[16];
        using (var sha1 = System.Security.Cryptography.SHA1.Create())
        {
            sha1.TransformBlock(bytes, 0, 16, hash, 0);
            sha1.TransformFinalBlock(nameBytes, 0, nameBytes.Length);
            Buffer.BlockCopy(sha1.Hash, 0, hash, 0, 16);
        }
        hash[6] = (byte)((hash[6] & 0x0f) | 0x50);
        hash[8] = (byte)((hash[8] & 0x3f) | 0x80);
        var guid = new Guid(hash);
        return guid.ToString() + ".";
    }
}
```

（若用其他语言，实现 RFC 4122 UUID v5，namespace = DNS = `6ba7b810-9dad-11d1-80b4-00c04fd430c8`，name = room_name 字符串即可。）

---

## 三、推荐流程：匹配微服务 → 客户端

### 1. 匹配微服务（无状态）

- 输入：玩家入队（user_id、段位、区域等）
- 输出：当凑满一局时，生成一个 **room_name**（如 `"room-" + 唯一ID`），并决定谁是房主（如列表第一个）
- 通过 Nakama 的 RPC 或 HTTP 把结果推给各客户端（或客户端轮询），例如：

```json
{
  "room_name": "room-a1b2c3d4",
  "is_host": true,
  "players": [
    { "user_id": "xxx", "username": "A" },
    { "user_id": "yyy", "username": "B" }
  ]
}
```

- 每个玩家收到的 `room_name` 相同，`is_host` 仅一人为 true。

### 2. 客户端：创建 or 加入 Relayed 房间

- **房主**（is_host == true）：
  1. 发 **MatchCreate**，`name = room_name`（如 `"room-a1b2c3d4"`）
  2. 收到 Match 信令后得到 `match_id`（格式 `uuid.`），可本地缓存

- **非房主**：
  1. 用上面约定算法 **RoomNameToMatchId(room_name)** 得到 `match_id`
  2. 发 **MatchJoin**，`match_id = match_id`
  3. 收到 Match 信令即进房成功

- **所有人**：
  - 之后局内消息一律用 **MatchDataSend**，`match_id` 用房主拿到的或自己算出来的均可（同一房间一致即可）
  - 服务器只做转发，不做权威校验

### 3. 时序简图

```
匹配微服务                    房主客户端                其他客户端                nakama-plus
    |                             |                         |                          |
    | 匹配成功，推送 room_name     |                         |                          |
    | + is_host / players         |                         |                          |
    |---------------------------->|                         |                          |
    |---------------------------->|                         |                          |
    |                             |  MatchCreate(name)      |                          |
    |                             |------------------------->                          |
    |                             |                         |  MatchJoin(match_id)     |
    |                             |                         |------------------------->|
    |                             |  Match 信令             |  Match 信令              |
    |                             |<-------------------------                          |
    |                             |  MatchDataSend          |  MatchDataSend           |
    |                             |<=================================================>  (转发)
```

---

## 四、注意事项

1. **谁先 Create**：必须保证「房主」先发 MatchCreate，其他人再 MatchJoin，否则 Join 时 stream 尚不存在会报 MATCH_NOT_FOUND。
2. **跨节点**：nakama-plus 下 Tracker 会同步各节点 presence，Relayed 房间的创建/加入/发消息会经现有 MessageRouter 跨节点转发，无需额外配置。
3. **热更新**：匹配微服务无状态，可独立发版；Relayed 只做转发，无 MatchLoop 状态，联机服务滚动更新影响小。

按此流程即可实现「匹配服务无状态 + 联机仅转发」，并支持热更新与水平扩容。
