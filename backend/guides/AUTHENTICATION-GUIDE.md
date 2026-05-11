# Authentication Guide

JWT authentication patterns for NestJS.

## Setup

1. Install dependencies:
```bash
npm install @nestjs/passport passport passport-jwt
npm install -D @types/passport-jwt
```

2. Configure JWT module:
```typescript
JwtModule.register({
  secret: process.env.JWT_SECRET,
  signOptions: { expiresIn: '1d' },
}),
```

## Guards

### JwtAuthGuard

```typescript
@Injectable()
export class JwtAuthGuard extends AuthGuard('jwt') {}
```

### RolesGuard

```typescript
@Injectable()
export class RolesGuard implements CanActivate {
  constructor(private reflector: Reflector) {}

  canActivate(context: ExecutionContext): boolean {
    const roles = this.reflector.getAllAndOverride<Role[]>(ROLES_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (!roles) return true;

    const { user } = context.switchToHttp().getRequest();
    return roles.some((role) => user.role === role);
  }
}
```

## Decorators

```typescript
export const ROLES_KEY = 'roles';
export const Roles = (...roles: Role[]) => SetMetadata(ROLES_KEY, roles);
```

## Usage

```typescript
@Controller('api/admin')
@UseGuards(JwtAuthGuard, RolesGuard)
export class AdminController {
  @Get('users')
  @Roles(Role.ADMIN)
  findAll() {
    return this.userService.findAll();
  }
}
```
