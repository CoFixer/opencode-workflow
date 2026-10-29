# API Integration Guide

This guide maps frontend screens to their required backend API endpoints. Use this when implementing data fetching for any screen.

## Table of Contents

- [Quick Reference](#quick-reference)
- [Public/Auth Routes](#publicauth-routes)
- [Admin Routes](#admin-routes)
- [Member Routes](#member-routes)
- [Shared/Common APIs](#sharedcommon-apis)
- [Implementation Patterns](#implementation-patterns)
- [After Successful Integration](#after-successful-integration)

---

## Quick Reference

| Route Group | Screens | Total API Calls |
|-------------|---------|-----------------|
| Public/Auth | 8 | ~6 endpoints |
| Admin | 10 | ~25 endpoints |
| Member | 10 | ~22 endpoints |
| Shared | - | 5 endpoints |

**Full API documentation:** [PROJECT_API.md](../../../.project/docs/PROJECT_API.md)

**Screen-to-API mapping:** [PROJECT_API_INTEGRATION.md](../../../.project/docs/PROJECT_API_INTEGRATION.md)

---

## Public/Auth Routes

### Login (`/`)
**Component:** `pages/auth/index.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Login | POST | `/auth/login` | Authenticate user |

### Registration (`/register`)
**Component:** `pages/auth/register.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Register | POST | `/users` | Create new user |

### Forgot Password (`/forgot-password`)
**Component:** `pages/auth/forgot-password.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Request OTP | POST | `/auth/forgot-password` | Send password reset OTP |
| Reset Password | POST | `/auth/reset-password` | Reset password with OTP |

### Member Signup (`/signup/member`)
**Component:** `pages/auth/signup/member.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Register | POST | `/users` | Create member (role: MEMBER) |

### Admin Signup (`/signup/admin`)
**Component:** `pages/auth/signup/admin.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Register | POST | `/users` | Create admin (role: ADMIN) |

---

## Admin Routes

### Admin Dashboard (`/admin`)
**Component:** `pages/admin/home.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Today's Meetings | GET | `/meetings/admin/today` | Get today's sessions |
| Check Login | GET | `/auth/check-login` | Verify authentication |

### Member List (`/admin/members`)
**Component:** `pages/admin/members.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Get Members | GET | `/users?role=MEMBER` | List admin's members |

### Member Detail (`/admin/member/:id`)
**Component:** `pages/admin/member-detail.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Get Member | GET | `/users/:id` | Get member info |
| Get Prescriptions | GET | `/exercise-prescriptions/member/:memberId` | Get member's exercises |

### Member Exercise History (`/admin/member/:id/exercise-history`)
**Component:** `pages/admin/member-exercise-history.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Exercise History | GET | `/exercise-days/member/:memberId/history` | Get exercise day summaries |
| Exercise Logs | GET | `/exercise-logs/member/:memberId/range` | Get detailed exercise logs |

### Member Survey History (`/admin/member/:id/survey-history`)
**Component:** `pages/admin/member-survey-history.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Survey History | GET | `/surveys/member/:memberId/history` | Get member's surveys |

### Admin Calendar (`/admin/calendar`)
**Component:** `pages/admin/calendar.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Get Meetings | GET | `/meetings/admin/range` | Get meetings for date range |

### Chat List (`/admin/chat`)
**Component:** `pages/admin/chat.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Get Rooms | GET | `/chat/rooms` | Get all chat rooms |

### Chat Detail (`/admin/chat/:id`)
**Component:** `pages/admin/chat-detail.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Get Room | GET | `/chat/rooms/:id` | Get room details |
| Get Messages | GET | `/chat/rooms/:id/messages` | Get chat messages |
| Send Message | POST | `/chat/rooms/:id/messages` | Send new message |
| Mark Read | PUT | `/chat/rooms/:id/read` | Mark messages as read |

### Create Session (`/admin/session/create`)
**Component:** `pages/admin/session-create.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Create Meeting | POST | `/meetings` | Create Zoom meeting |

### Session Detail (`/admin/session/:id`)
**Component:** `pages/admin/session-detail.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Get Meeting | GET | `/meetings/:id` | Get meeting details |
| Update Meeting | PATCH | `/meetings/:id` | Update meeting info |
| Complete Meeting | PATCH | `/meetings/:id/complete` | Mark as completed |
| Cancel Meeting | PATCH | `/meetings/:id/cancel` | Cancel the meeting |

---

## Member Routes

### Member Dashboard (`/member`)
**Component:** `pages/member/home.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Today's Survey | GET | `/surveys/daily/today` | Check if survey completed |
| Exercises with Logs | GET | `/exercise-prescriptions/member/:id/with-logs` | Today's exercises + progress |
| Next Meeting | GET | `/meetings/member/next` | Get upcoming session |

### Member Calendar (`/member/calendar`)
**Component:** `pages/member/calendar.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Get Meetings | GET | `/meetings/member/range` | Get meetings for date range |

### Exercise List (`/member/exercise`)
**Component:** `pages/member/exercise.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Get Prescriptions | GET | `/exercise-prescriptions/member/:id` | Get assigned exercises |
| Get Logs | GET | `/exercise-logs` | Get today's exercise logs |

### Exercise Detail (`/member/exercise/:id`)
**Component:** `pages/member/exercise-detail.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Get Exercise | GET | `/exercises/:id` | Get exercise details |
| Log Exercise | POST | `/exercise-logs` | Record exercise completion |

### Exercise History (`/member/exercise/history`)
**Component:** `pages/member/exercise-history.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Get History | GET | `/exercise-days/history` | Get exercise day history |
| Get Logs | GET | `/exercise-logs/range` | Get logs for date range |

### Daily Survey (`/member/survey`)
**Component:** `pages/member/survey.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Submit Survey | POST | `/surveys/daily` | Submit daily survey |

### Survey History (`/member/survey/history`)
**Component:** `pages/member/survey-history.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Get History | GET | `/surveys/history` | Get survey history |

### Chat List (`/member/chat`)
**Component:** `pages/member/chat.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Get Rooms | GET | `/chat/rooms` | Get all chat rooms |

### Chat Detail (`/member/chat/:id`)
**Component:** `pages/member/chat-detail.tsx`

| API | Method | Endpoint | Purpose |
|-----|--------|----------|---------|
| Get Room | GET | `/chat/rooms/:id` | Get room details |
| Get Messages | GET | `/chat/rooms/:id/messages` | Get chat messages |
| Send Message | POST | `/chat/rooms/:id/messages` | Send new message |
| Mark Read | PUT | `/chat/rooms/:id/read` | Mark messages as read |

---

## Shared/Common APIs

These APIs are used across multiple screens:

| API | Method | Endpoint | Used For |
|-----|--------|----------|----------|
| Check Login | GET | `/auth/check-login` | Verify session on protected routes |
| Logout | GET | `/auth/logout` | User logout |
| Refresh Token | GET | `/auth/refresh-access-token` | Token refresh (automatic) |
| Get Profile | GET | `/users/:id` | User profile pages |
| Update Profile | PATCH | `/users/:id` | Profile editing |
| Register FCM | POST | `/auth/register-fcm-token` | Push notifications |

---

## Implementation Patterns

### Creating an API Service

```typescript
// services/httpServices/meetingService.ts
import { httpService } from '../httpService';
import type { Meeting, CreateMeetingDto } from '~/types/meeting';

export const meetingService = {
  getTodayMeetings: () =>
    httpService.get<Meeting[]>('/meetings/admin/today'),

  createMeeting: (data: CreateMeetingDto) =>
    httpService.post<Meeting>('/meetings', data),

  getMeeting: (id: string) =>
    httpService.get<Meeting>(`/meetings/${id}`),
};
```

### Creating a Redux Slice with Thunks

```typescript
// redux/features/meetingSlice.ts
import { createSlice, createAsyncThunk } from '@reduxjs/toolkit';
import { meetingService } from '~/services/httpServices/meetingService';

export const fetchTodayMeetings = createAsyncThunk(
  'meetings/fetchToday',
  async () => {
    const response = await meetingService.getTodayMeetings();
    return response.data;
  }
);

const meetingSlice = createSlice({
  name: 'meetings',
  initialState: {
    meetings: [],
    loading: false,
    error: null,
  },
  reducers: {},
  extraReducers: (builder) => {
    builder
      .addCase(fetchTodayMeetings.pending, (state) => {
        state.loading = true;
      })
      .addCase(fetchTodayMeetings.fulfilled, (state, action) => {
        state.loading = false;
        state.meetings = action.payload;
      })
      .addCase(fetchTodayMeetings.rejected, (state, action) => {
        state.loading = false;
        state.error = action.error.message;
      });
  },
});
```

### Using in a Component

```typescript
// app/(admin)/home.tsx
import { useEffect } from 'react';
import { View, Text, FlatList, ActivityIndicator } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useAppDispatch, useAppSelector } from '@/redux/store/hooks';
import { fetchTodayMeetings } from '@/redux/features/meetingSlice';
import { MeetingCard } from '@/components/MeetingCard';

export default function AdminHome() {
  const dispatch = useAppDispatch();
  const { meetings, loading } = useAppSelector((state) => state.meetings);

  useEffect(() => {
    dispatch(fetchTodayMeetings());
  }, [dispatch]);

  if (loading) {
    return (
      <View className="flex-1 items-center justify-center">
        <ActivityIndicator size="large" />
      </View>
    );
  }

  return (
    <SafeAreaView className="flex-1 bg-background">
      <FlatList
        data={meetings}
        keyExtractor={(item) => item.id}
        renderItem={({ item }) => <MeetingCard meeting={item} />}
        contentContainerClassName="p-4 gap-4"
      />
    </SafeAreaView>
  );
}
```

---

## After Successful Integration

Once your API integration is working correctly, follow these steps:

### Integration Verification Checklist

- [ ] API calls return expected data
- [ ] Loading states display correctly
- [ ] Error states are handled gracefully
- [ ] TypeScript types match API response
- [ ] Redux state updates properly
- [ ] Component renders data correctly
- [ ] No console errors or warnings

### Create Pull Request

When integration is complete and verified, create a PR to the dev branch:

```bash
# Check your changes
git status
git diff

# Stage and commit
git add .
git commit -m "feat: Integrate [feature] API endpoints"

# Push and create PR
git push -u origin HEAD
gh pr create --base dev --title "feat: [Feature] API integration" --body "$(cat <<'EOF'
## Summary
- Integrated [endpoint] API for [feature]
- Added Redux slice for state management
- Created HTTP service methods

## APIs Integrated
| Endpoint | Method | Purpose |
|----------|--------|---------|
| /api/example | GET | Fetch data |

## Test Plan
- [ ] Verified API responses in Network tab
- [ ] Tested loading/error states
- [ ] Confirmed data displays correctly

---
Generated with [OpenCode](https://OpenCode.com/OpenCode-code)
EOF
)"
```

For detailed PR creation workflow, see [Create Dev PR](create-dev-pr.md).

---

## Related Resources

- [Data Fetching Guide](data-fetching.md) - HttpService patterns
- [Common Patterns](common-patterns.md) - Redux and form patterns
- [Complete Examples](complete-examples.md) - Full working examples
- [Create Dev PR](create-dev-pr.md) - Submit integration for review
