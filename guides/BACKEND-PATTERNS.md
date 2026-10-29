# Backend Patterns (NestJS)

Generic NestJS conventions for any project using the `.opencode` workflow. Project-specific commands, ports, and module names belong in `.project/docs/`, not here.

> **Before coding**: read the project's `PROJECT_KNOWLEDGE` / `PROJECT_API` docs and any `AGENTS.md`. If a project convention conflicts with this guide, the project wins.

## Response shape

Use **one** envelope consistently. Two common choices:

```typescript
// Interceptor-based envelope
{ data: unknown, status: 'success', message?: string, statusCode: number, timestamp: string }

// Or minimal envelope
{ success: true, data: unknown, message?: string }
```

Rules:
- Pick the project's existing envelope; do not introduce a second one.
- Errors: `{ statusCode, message, error, timestamp }` unless the project defines otherwise.
- Never leak stack traces or internal error codes to clients.

## Controller

Keep controllers thin: validation + delegation.

```typescript
@Controller('resources')
export class ResourceController {
  constructor(private readonly service: ResourceService) {}

  @Post()
  @UseGuards(JwtAuthGuard, RolesGuard)
  @Roles(Role.ADMIN)
  create(@Body() dto: CreateResourceDto) {
    return this.service.create(dto);
  }
}
```

Checklist:
- DTO on every body/query/param (`class-validator`).
- Explicit guards on protected routes (avoid relying only on a global guard).
- Swagger decorators when the project uses Swagger.
- No business logic in the controller.

## Service

```typescript
@Injectable()
export class ResourceService {
  private readonly logger = new Logger(ResourceService.name);

  constructor(private readonly repository: ResourceRepository) {}

  async create(dto: CreateResourceDto) {
    const entity = this.repository.create(dto);
    return this.repository.save(entity);
  }
}
```

Rules:
- Throw Nest HTTP exceptions (`NotFoundException`, `ForbiddenException`, …), not raw `Error`.
- Log with context; never log secrets or tokens.
- Keep transactions in the service, not the controller.
- Emit side effects (queues, events) through injected providers.

## Repository / data access

TypeORM 0.3+ uses injected repositories. Avoid the deprecated `@EntityRepository` decorator.

```typescript
@Injectable()
export class ResourceRepository {
  constructor(
    @InjectRepository(Resource)
    private readonly repo: Repository<Resource>,
  ) {}

  findByOwner(ownerId: string) {
    return this.repo.find({ where: { ownerId } });
  }
}
```

Rules:
- Always scope tenant-owned queries by the tenant key (e.g. `workspaceId`).
- Prefer query builder for complex joins; parameterize everything.
- Pagination: return `{ items, total, page, totalPages }` or the project's documented shape.

## DTO + validation

```typescript
export class CreateResourceDto {
  @IsString()
  @IsNotEmpty()
  @MaxLength(255)
  name!: string;

  @IsOptional()
  @IsInt()
  @Min(0)
  quantity?: number;
}
```

- Enable `whitelist` + `forbidNonWhitelisted` in the global validation pipe.
- Validate enums with `@IsEnum`.
- Do not accept role/tenant IDs from the client when they can be derived from the session.

## Auth & RBAC

- Guards: authentication → authorization → resource ownership.
- Decorators like `@Public()`, `@Roles()`, `@CurrentUser()` keep controllers readable.
- Enforce the same rule at the query level (defense in depth), not only in the guard.
- Long-lived credentials (API keys) should be hashed at rest.

## Errors & logging

- Central `ExceptionFilter` for consistent error bodies.
- Structured logs with request ID / user ID where available.
- Log failures at the boundary; rethrow domain-appropriate exceptions.

## Testing

```typescript
describe('ResourceService', () => {
  let service: ResourceService;
  const repository = { save: jest.fn(), create: jest.fn() };

  beforeEach(async () => {
    const module = await Test.createTestingModule({
      providers: [
        ResourceService,
        { provide: ResourceRepository, useValue: repository },
      ],
    }).compile();
    service = module.get(ResourceService);
  });

  it('creates a resource', async () => {
    repository.create.mockReturnValue({ name: 'x' });
    repository.save.mockResolvedValue({ id: '1', name: 'x' });
    await expect(service.create({ name: 'x' })).resolves.toEqual({ id: '1', name: 'x' });
  });
});
```

- Unit tests for services and guards.
- E2E tests for auth boundaries and critical write paths.
- Use a test database or transaction rollback; never hit production.

## Commands

Read the project's `package.json` rather than assuming script names. Typical:

```bash
npm run start:dev
npm run build
npm run lint
npm test
npm run test:e2e
npm run migration:generate -- -n MigrationName
npm run migration:run
```

## Where project specifics live

| Need | Location |
|------|----------|
| Module map, stack, ports | `.project/docs/PROJECT_KNOWLEDGE.MD` |
| Endpoints | `.project/docs/PROJECT_API.MD` |
| Entities | `.project/docs/PROJECT_DATABASE.MD` |
| Current gaps | `.project/status/` |

Do **not** hardcode project names, package lists, or ports in `.opencode`.
