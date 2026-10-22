-- =====================================================================
-- Carteira de clientes Amazon — estrutura inicial
-- Rodar inteiro no SQL Editor do Supabase (projeto novo).
-- =====================================================================

-- ---------- Tipos ----------
create type public.funcao_colaborador as enum ('head', 'gestor_ads', 'operador_contas', 'gestor_contas');
create type public.status_cliente     as enum ('ativo', 'pausado', 'saiu');


-- ---------- Colaboradores ----------
-- Um registro por login. A pessoa escolhe a função ao criar a conta e já entra;
-- o HEAD pode trocar a função ou remover o acesso pela tela "Equipe".
create table public.colaboradores (
  id        uuid primary key references auth.users(id) on delete cascade,
  nome      text not null,
  email     text not null,
  funcao    public.funcao_colaborador,
  ativo     boolean not null default true,   -- false = acesso removido pelo HEAD
  criado_em timestamptz not null default now()
);

-- Cria o colaborador automaticamente quando alguém cria conta
create or replace function public.novo_colaborador()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.colaboradores (id, nome, email, funcao)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data->>'nome'), ''), split_part(new.email, '@', 1)),
    new.email,
    -- HEAD nunca é escolhido no cadastro; só é definido pelo SQL ou por outro HEAD
    case when new.raw_user_meta_data->>'funcao' in ('gestor_ads', 'operador_contas', 'gestor_contas')
         then (new.raw_user_meta_data->>'funcao')::public.funcao_colaborador end
  );
  return new;
end; $$;

create trigger ao_criar_usuario
  after insert on auth.users
  for each row execute function public.novo_colaborador();

-- Funções de apoio para as regras de acesso
create or replace function public.eh_ativo()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.colaboradores where id = auth.uid() and ativo and funcao is not null);
$$;

create or replace function public.eh_head()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.colaboradores where id = auth.uid() and ativo and funcao = 'head');
$$;


-- ---------- Clientes ----------
create table public.clientes (
  id                 uuid primary key default gen_random_uuid(),
  nome               text not null,
  loja               text,
  status             public.status_cliente not null default 'ativo',
  data_entrada       date default current_date,
  resp_gestor_ads    uuid references public.colaboradores(id) on delete set null,
  resp_operador      uuid references public.colaboradores(id) on delete set null,
  resp_gestor_contas uuid references public.colaboradores(id) on delete set null,
  -- % de variação mensal que ainda conta como "estagnado" (por cliente)
  limiar_estagnacao  numeric(5,2) not null default 5 check (limiar_estagnacao >= 0 and limiar_estagnacao <= 100),
  observacoes        text,
  nome_planilha      text,  -- nome da conta na planilha de métricas, quando diferente do nome
  criado_por         uuid references public.colaboradores(id) on delete set null default auth.uid(),
  criado_em          timestamptz not null default now(),
  atualizado_em      timestamptz not null default now()
);
create index on public.clientes (status);

create or replace function public.tocar_atualizado_em()
returns trigger language plpgsql as $$
begin new.atualizado_em = now(); return new; end; $$;

create trigger clientes_atualizado
  before update on public.clientes
  for each row execute function public.tocar_atualizado_em();


-- ---------- Histórico de status ----------
create table public.historico_status (
  id              bigint generated always as identity primary key,
  cliente_id      uuid not null references public.clientes(id) on delete cascade,
  status_anterior public.status_cliente,
  status_novo     public.status_cliente not null,
  motivo          text,
  alterado_por    uuid references public.colaboradores(id) on delete set null,
  alterado_em     timestamptz not null default now()
);
create index on public.historico_status (cliente_id, alterado_em desc);

-- Registra o status inicial quando o cliente é cadastrado
create or replace function public.registrar_cadastro()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.historico_status (cliente_id, status_anterior, status_novo, alterado_por)
  values (new.id, null, new.status, new.criado_por);
  return new;
end; $$;

create trigger clientes_cadastro
  after insert on public.clientes
  for each row execute function public.registrar_cadastro();

-- Única forma de mudar o status: sempre deixa rastro no histórico
create or replace function public.alterar_status(p_cliente uuid, p_status public.status_cliente, p_motivo text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_atual public.status_cliente;
begin
  if not public.eh_ativo() then raise exception 'Sem permissão para alterar status'; end if;
  select status into v_atual from public.clientes where id = p_cliente for update;
  if not found then raise exception 'Cliente não encontrado'; end if;
  if v_atual = p_status then return; end if;
  update public.clientes set status = p_status where id = p_cliente;
  insert into public.historico_status (cliente_id, status_anterior, status_novo, motivo, alterado_por)
  values (p_cliente, v_atual, p_status, nullif(trim(p_motivo), ''), auth.uid());
end; $$;

-- Só o HEAD troca funções e remove ou devolve acessos
create or replace function public.definir_colaborador(p_id uuid, p_funcao public.funcao_colaborador, p_ativo boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_head() then raise exception 'Apenas o HEAD pode gerenciar a equipe'; end if;
  if p_id = auth.uid() then raise exception 'Você não pode alterar o próprio acesso'; end if;
  if p_ativo and p_funcao is null then raise exception 'Defina a função antes de liberar o acesso'; end if;
  update public.colaboradores set funcao = p_funcao, ativo = p_ativo where id = p_id;
end; $$;


-- ---------- Métricas mensais (preparado para a importação futura) ----------
create table public.metricas_mensais (
  id           bigint generated always as identity primary key,
  cliente_id   uuid not null references public.clientes(id) on delete cascade,
  mes          date not null,            -- sempre o dia 1 do mês
  faturamento  numeric(14,2),
  acos         numeric(6,2),             -- em %
  tacos        numeric(6,2),             -- em %
  importado_em timestamptz not null default now(),
  unique (cliente_id, mes)
);


-- =====================================================================
-- Regras de acesso (RLS)
-- =====================================================================
alter table public.colaboradores    enable row level security;
alter table public.clientes         enable row level security;
alter table public.historico_status enable row level security;
alter table public.metricas_mensais enable row level security;

-- Colaboradores: cada um vê o próprio registro; ativos veem a equipe toda.
-- Ninguém edita direto: mudanças passam por definir_colaborador().
create policy "ver colaboradores" on public.colaboradores
  for select to authenticated using (id = auth.uid() or public.eh_ativo());
revoke insert, update, delete on public.colaboradores from anon, authenticated;

-- Clientes: todo colaborador ativo vê, cadastra e edita; só o HEAD exclui.
create policy "ver clientes"       on public.clientes for select to authenticated using (public.eh_ativo());
create policy "cadastrar clientes" on public.clientes for insert to authenticated with check (public.eh_ativo());
create policy "editar clientes"    on public.clientes for update to authenticated using (public.eh_ativo()) with check (public.eh_ativo());
create policy "excluir clientes"   on public.clientes for delete to authenticated using (public.eh_head());
-- O status não pode ser editado direto (só via alterar_status), para o histórico nunca falhar
revoke update on public.clientes from anon, authenticated;
grant update (nome, loja, data_entrada, resp_gestor_ads, resp_operador, resp_gestor_contas, limiar_estagnacao, observacoes, nome_planilha)
  on public.clientes to authenticated;

-- Histórico: somente leitura pelo app
create policy "ver historico" on public.historico_status for select to authenticated using (public.eh_ativo());
revoke insert, update, delete on public.historico_status from anon, authenticated;

-- Métricas
create policy "ver metricas"     on public.metricas_mensais for select to authenticated using (public.eh_ativo());
create policy "importar metricas" on public.metricas_mensais for insert to authenticated with check (public.eh_ativo());
create policy "corrigir metricas" on public.metricas_mensais for update to authenticated using (public.eh_ativo()) with check (public.eh_ativo());
create policy "excluir metricas" on public.metricas_mensais for delete to authenticated using (public.eh_head());

-- Funções chamáveis pelo app só por quem está logado
revoke execute on function public.alterar_status(uuid, public.status_cliente, text) from public, anon;
revoke execute on function public.definir_colaborador(uuid, public.funcao_colaborador, boolean) from public, anon;
grant  execute on function public.alterar_status(uuid, public.status_cliente, text) to authenticated;
grant  execute on function public.definir_colaborador(uuid, public.funcao_colaborador, boolean) to authenticated;


-- =====================================================================
-- Problemas e chamados
-- Uma conta pode ter vários problemas; cada problema pode gerar vários chamados.
-- Concluir um chamado NÃO resolve o problema: cada um tem o próprio status.
-- =====================================================================
create type public.gravidade_problema as enum ('baixa', 'media', 'alta', 'critica');
create type public.status_problema    as enum ('aberto', 'em_andamento', 'resolvido');
create type public.status_chamado     as enum ('a_abrir', 'aberto', 'concluido');

create table public.problemas (
  id            uuid primary key default gen_random_uuid(),
  cliente_id    uuid not null references public.clientes(id) on delete cascade,
  titulo        text not null,
  descricao     text,
  gravidade     public.gravidade_problema not null default 'media',
  status        public.status_problema not null default 'aberto',
  responsavel   uuid references public.colaboradores(id) on delete set null,
  criado_por    uuid references public.colaboradores(id) on delete set null default auth.uid(),
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  resolvido_em  timestamptz
);
create index on public.problemas (cliente_id);

create table public.chamados (
  id            uuid primary key default gen_random_uuid(),
  problema_id   uuid not null references public.problemas(id) on delete cascade,
  assunto       text not null,
  observacoes   text,
  status        public.status_chamado not null default 'a_abrir',
  responsavel   uuid references public.colaboradores(id) on delete set null,
  criado_por    uuid references public.colaboradores(id) on delete set null default auth.uid(),
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  aberto_em     timestamptz,
  concluido_em  timestamptz
);
create index on public.chamados (problema_id);
create index on public.chamados (status);

-- Datas preenchidas automaticamente
create or replace function public.datas_problema()
returns trigger language plpgsql as $$
begin
  new.atualizado_em = now();
  if new.status = 'resolvido' then
    if tg_op = 'INSERT' or old.status <> 'resolvido' then new.resolvido_em = now(); end if;
  else
    new.resolvido_em = null;
  end if;
  return new;
end; $$;

create trigger problemas_datas
  before insert or update on public.problemas
  for each row execute function public.datas_problema();

create or replace function public.datas_chamado()
returns trigger language plpgsql as $$
begin
  new.atualizado_em = now();
  if new.status in ('aberto', 'concluido') and new.aberto_em is null then new.aberto_em = now(); end if;
  if new.status = 'concluido' then
    if tg_op = 'INSERT' or old.status <> 'concluido' then new.concluido_em = now(); end if;
  else
    new.concluido_em = null;
  end if;
  return new;
end; $$;

create trigger chamados_datas
  before insert or update on public.chamados
  for each row execute function public.datas_chamado();

-- Regras de acesso: todo colaborador ativo vê, cria e edita;
-- excluir fica com quem criou ou com o HEAD.
alter table public.problemas enable row level security;
alter table public.chamados  enable row level security;

create policy "ver problemas"     on public.problemas for select to authenticated using (public.eh_ativo());
create policy "criar problemas"   on public.problemas for insert to authenticated with check (public.eh_ativo());
create policy "editar problemas"  on public.problemas for update to authenticated using (public.eh_ativo()) with check (public.eh_ativo());
create policy "excluir problemas" on public.problemas for delete to authenticated
  using (public.eh_head() or (public.eh_ativo() and criado_por = auth.uid()));

create policy "ver chamados"     on public.chamados for select to authenticated using (public.eh_ativo());
create policy "criar chamados"   on public.chamados for insert to authenticated with check (public.eh_ativo());
create policy "editar chamados"  on public.chamados for update to authenticated using (public.eh_ativo()) with check (public.eh_ativo());
create policy "excluir chamados" on public.chamados for delete to authenticated
  using (public.eh_head() or (public.eh_ativo() and criado_por = auth.uid()));


-- =====================================================================
-- Aba Ads
-- Situação atual (um texto por cliente) e timeline de registros por data:
-- alterações realizadas e demandas. Tudo isso aparece só na aba Ads.
-- =====================================================================
create type public.tipo_registro_ads as enum ('alteracao', 'demanda');

create table public.ads_situacao (
  cliente_id     uuid primary key references public.clientes(id) on delete cascade,
  texto          text,
  atualizado_por uuid references public.colaboradores(id) on delete set null,
  atualizado_em  timestamptz not null default now()
);

create table public.ads_registros (
  id            uuid primary key default gen_random_uuid(),
  cliente_id    uuid not null references public.clientes(id) on delete cascade,
  tipo          public.tipo_registro_ads not null,
  data          date not null default current_date,
  texto         text not null,
  concluida     boolean not null default false,   -- só vale para demandas
  concluida_em  timestamptz,
  autor         uuid references public.colaboradores(id) on delete set null default auth.uid(),
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index on public.ads_registros (cliente_id, data desc);

create or replace function public.ads_situacao_autor()
returns trigger language plpgsql as $$
begin
  new.atualizado_por = auth.uid();
  new.atualizado_em = now();
  return new;
end; $$;

create trigger ads_situacao_autor
  before insert or update on public.ads_situacao
  for each row execute function public.ads_situacao_autor();

create or replace function public.ads_registro_datas()
returns trigger language plpgsql as $$
begin
  new.atualizado_em = now();
  if new.tipo <> 'demanda' then new.concluida = false; end if;
  if new.concluida then
    if tg_op = 'INSERT' or not old.concluida then new.concluida_em = now(); end if;
  else
    new.concluida_em = null;
  end if;
  return new;
end; $$;

create trigger ads_registros_datas
  before insert or update on public.ads_registros
  for each row execute function public.ads_registro_datas();

alter table public.ads_situacao  enable row level security;
alter table public.ads_registros enable row level security;

create policy "ver situacao ads"    on public.ads_situacao for select to authenticated using (public.eh_ativo());
create policy "criar situacao ads"  on public.ads_situacao for insert to authenticated with check (public.eh_ativo());
create policy "editar situacao ads" on public.ads_situacao for update to authenticated using (public.eh_ativo()) with check (public.eh_ativo());

create policy "ver registros ads"     on public.ads_registros for select to authenticated using (public.eh_ativo());
create policy "criar registros ads"   on public.ads_registros for insert to authenticated with check (public.eh_ativo());
create policy "editar registros ads"  on public.ads_registros for update to authenticated using (public.eh_ativo()) with check (public.eh_ativo());
create policy "excluir registros ads" on public.ads_registros for delete to authenticated
  using (public.eh_head() or (public.eh_ativo() and autor = auth.uid()));


-- =====================================================================
-- Configurações gerais e Listings
-- Rota de cada solicitação: solicitado → em processo → catalogação → concluído
-- =====================================================================
create table public.configuracoes (
  chave          text primary key,
  valor          text,
  atualizado_por uuid references public.colaboradores(id) on delete set null,
  atualizado_em  timestamptz not null default now()
);
insert into public.configuracoes (chave) values ('planilha_catalogacao_padrao');

create or replace function public.config_autor()
returns trigger language plpgsql as $$
begin new.atualizado_por = auth.uid(); new.atualizado_em = now(); return new; end; $$;

create trigger configuracoes_autor
  before update on public.configuracoes
  for each row execute function public.config_autor();

create type public.etapa_listing       as enum ('solicitado', 'em_processo', 'catalogacao', 'concluido');
create type public.tipo_evento_listing as enum ('etapa', 'alteracao');

create table public.listings (
  id                   uuid primary key default gen_random_uuid(),
  numero               bigint generated always as identity unique,   -- número da solicitação
  cliente_id           uuid not null references public.clientes(id) on delete cascade,
  qtd_produtos         integer not null check (qtd_produtos > 0),
  data_pedido          date not null default current_date,
  planilha_url         text,
  listing_url          text,
  etapa                public.etapa_listing not null default 'solicitado',
  data_criacao_listing date,
  catalogados          integer not null default 0,
  impedimento          text,
  criado_por           uuid references public.colaboradores(id) on delete set null default auth.uid(),
  criado_em            timestamptz not null default now(),
  atualizado_em        timestamptz not null default now(),
  concluido_em         timestamptz,
  constraint catalogados_validos check (catalogados >= 0 and catalogados <= qtd_produtos),
  constraint aprovado_tem_data   check (etapa in ('solicitado', 'em_processo') or data_criacao_listing is not null),
  constraint concluido_completo  check (etapa <> 'concluido' or catalogados = qtd_produtos)
);
create index on public.listings (cliente_id);
create index on public.listings (etapa);

create table public.listing_eventos (
  id         bigint generated always as identity primary key,
  listing_id uuid not null references public.listings(id) on delete cascade,
  tipo       public.tipo_evento_listing not null,
  etapa_de   public.etapa_listing,
  etapa_para public.etapa_listing,
  nota       text,
  autor      uuid references public.colaboradores(id) on delete set null default auth.uid(),
  criado_em  timestamptz not null default now()
);
create index on public.listing_eventos (listing_id, criado_em);

-- Antes de gravar: datas e link padrão da planilha
create or replace function public.listing_antes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.atualizado_em = now();
  if tg_op = 'INSERT' and nullif(trim(coalesce(new.planilha_url, '')), '') is null then
    select valor into new.planilha_url from public.configuracoes where chave = 'planilha_catalogacao_padrao';
  end if;
  if new.etapa = 'concluido' then
    if tg_op = 'INSERT' or old.etapa <> 'concluido' then new.concluido_em = now(); end if;
  else
    new.concluido_em = null;
  end if;
  return new;
end; $$;

create trigger listings_antes
  before insert or update on public.listings
  for each row execute function public.listing_antes();

-- Depois de gravar: toda mudança de etapa vai para o histórico
create or replace function public.listing_depois()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.listing_eventos (listing_id, tipo, etapa_para, autor) values (new.id, 'etapa', new.etapa, auth.uid());
  elsif new.etapa is distinct from old.etapa then
    insert into public.listing_eventos (listing_id, tipo, etapa_de, etapa_para, autor) values (new.id, 'etapa', old.etapa, new.etapa, auth.uid());
  end if;
  return null;
end; $$;

create trigger listings_depois
  after insert or update on public.listings
  for each row execute function public.listing_depois();

alter table public.configuracoes   enable row level security;
alter table public.listings        enable row level security;
alter table public.listing_eventos enable row level security;

create policy "ver configuracoes"    on public.configuracoes for select to authenticated using (public.eh_ativo());
create policy "editar configuracoes" on public.configuracoes for update to authenticated using (public.eh_ativo()) with check (public.eh_ativo());
revoke insert, delete on public.configuracoes from anon, authenticated;

create policy "ver listings"     on public.listings for select to authenticated using (public.eh_ativo());
create policy "criar listings"   on public.listings for insert to authenticated with check (public.eh_ativo());
create policy "editar listings"  on public.listings for update to authenticated using (public.eh_ativo()) with check (public.eh_ativo());
create policy "excluir listings" on public.listings for delete to authenticated
  using (public.eh_head() or (public.eh_ativo() and criado_por = auth.uid()));

-- Pelo app só entram pedidos de alteração; mudanças de etapa são registradas sozinhas
create policy "ver eventos listing"       on public.listing_eventos for select to authenticated using (public.eh_ativo());
create policy "registrar alteracao"       on public.listing_eventos for insert to authenticated with check (public.eh_ativo() and tipo = 'alteracao');
revoke update, delete on public.listing_eventos from anon, authenticated;


-- =====================================================================
-- Demanda de campanha a partir de um listing concluído
-- =====================================================================
alter table public.listings add column if not exists demanda_ads_id uuid references public.ads_registros(id) on delete set null;

-- =====================================================================
-- Modo dev
-- A palavra-chave fica numa tabela que o app não consegue ler;
-- só as funções abaixo comparam o que foi digitado.
-- =====================================================================
create table public.segredos (
  chave text primary key,
  valor text not null
);
alter table public.segredos enable row level security;
revoke all on public.segredos from anon, authenticated;

create or replace function public.verificar_modo_dev(p_chave text)
returns boolean language plpgsql security definer set search_path = public as $$
declare ok boolean;
begin
  if auth.uid() is null then return false; end if;
  select exists (select 1 from public.segredos where chave = 'modo_dev' and valor = p_chave) into ok;
  if not ok then perform pg_sleep(1); end if;   -- atrasa tentativas de adivinhar
  return ok;
end; $$;

create or replace function public.dev_definir_colaborador(p_chave text, p_id uuid, p_funcao public.funcao_colaborador, p_ativo boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.verificar_modo_dev(p_chave) then raise exception 'Palavra-chave do modo dev incorreta'; end if;
  if p_ativo and p_funcao is null then raise exception 'Defina a função antes de liberar o acesso'; end if;
  update public.colaboradores set funcao = p_funcao, ativo = p_ativo where id = p_id;
end; $$;

revoke execute on function public.verificar_modo_dev(text) from public, anon;
revoke execute on function public.dev_definir_colaborador(text, uuid, public.funcao_colaborador, boolean) from public, anon;
grant  execute on function public.verificar_modo_dev(text) to authenticated;
grant  execute on function public.dev_definir_colaborador(text, uuid, public.funcao_colaborador, boolean) to authenticated;

-- A palavra-chave do modo dev NÃO fica aqui: ela está em supabase/modo-dev.sql,
-- que não vai para o GitHub.


-- =====================================================================
-- Promoções e eventos
-- =====================================================================
create type public.tipo_promocao as enum ('desconto_preco', 'melhor_oferta', 'cupom', 'promocao', 'desconto_pix');

create table public.promocoes (
  id            uuid primary key default gen_random_uuid(),
  cliente_id    uuid not null references public.clientes(id) on delete cascade,
  tipo          public.tipo_promocao not null,
  percentual    numeric(5,2) not null check (percentual > 0 and percentual <= 100),
  data_inicio   date not null,
  data_fim      date not null,              -- último dia da promoção
  observacao    text,
  criado_por    uuid references public.colaboradores(id) on delete set null default auth.uid(),
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint periodo_valido check (data_fim >= data_inicio)
);
create index on public.promocoes (cliente_id);
create index on public.promocoes (data_fim);

create table public.eventos (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null,
  data_inicio date,                         -- opcional: o evento pode ser anunciado sem data
  data_fim    date,
  criado_por  uuid references public.colaboradores(id) on delete set null default auth.uid(),
  criado_em   timestamptz not null default now(),
  constraint periodo_evento check (data_inicio is null or data_fim is null or data_fim >= data_inicio)
);

-- Etapas: 1 informar o cliente, 2 cliente interessado, 3 definir produtos, 4 tudo pronto
create table public.evento_clientes (
  id             uuid primary key default gen_random_uuid(),
  evento_id      uuid not null references public.eventos(id) on delete cascade,
  cliente_id     uuid not null references public.clientes(id) on delete cascade,
  etapa          smallint not null default 1 check (etapa between 1 and 4),
  nao_participa  boolean not null default false,
  planilha_url   text,
  atualizado_por uuid references public.colaboradores(id) on delete set null,
  atualizado_em  timestamptz not null default now(),
  unique (evento_id, cliente_id)
);
create index on public.evento_clientes (evento_id);

create or replace function public.tocar_evento_cliente()
returns trigger language plpgsql as $$
begin new.atualizado_por = auth.uid(); new.atualizado_em = now(); return new; end; $$;

create trigger evento_clientes_autor
  before insert or update on public.evento_clientes
  for each row execute function public.tocar_evento_cliente();

-- Evento novo: entram todos os clientes ativos e pausados
create or replace function public.preencher_evento()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.evento_clientes (evento_id, cliente_id)
  select new.id, c.id from public.clientes c where c.status in ('ativo', 'pausado')
  on conflict do nothing;
  return new;
end; $$;

create trigger eventos_preencher
  after insert on public.eventos
  for each row execute function public.preencher_evento();

-- Cliente novo: entra nos eventos cuja data de início (data de corte) ainda não chegou,
-- ou que ainda não têm data
create or replace function public.cliente_em_eventos()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status in ('ativo', 'pausado') then
    insert into public.evento_clientes (evento_id, cliente_id)
    select e.id, new.id from public.eventos e
    where e.data_inicio is null or current_date < e.data_inicio
    on conflict do nothing;
  end if;
  return new;
end; $$;

create trigger clientes_em_eventos
  after insert on public.clientes
  for each row execute function public.cliente_em_eventos();

create or replace function public.tocar_promocao()
returns trigger language plpgsql as $$
begin new.atualizado_em = now(); return new; end; $$;

create trigger promocoes_atualizado
  before update on public.promocoes
  for each row execute function public.tocar_promocao();

alter table public.promocoes       enable row level security;
alter table public.eventos         enable row level security;
alter table public.evento_clientes enable row level security;

create policy "ver promocoes"     on public.promocoes for select to authenticated using (public.eh_ativo());
create policy "criar promocoes"   on public.promocoes for insert to authenticated with check (public.eh_ativo());
create policy "editar promocoes"  on public.promocoes for update to authenticated using (public.eh_ativo()) with check (public.eh_ativo());
create policy "excluir promocoes" on public.promocoes for delete to authenticated
  using (public.eh_head() or (public.eh_ativo() and criado_por = auth.uid()));

create policy "ver eventos"     on public.eventos for select to authenticated using (public.eh_ativo());
create policy "criar eventos"   on public.eventos for insert to authenticated with check (public.eh_ativo());
create policy "editar eventos"  on public.eventos for update to authenticated using (public.eh_ativo()) with check (public.eh_ativo());
create policy "excluir eventos" on public.eventos for delete to authenticated
  using (public.eh_head() or (public.eh_ativo() and criado_por = auth.uid()));

create policy "ver clientes do evento"     on public.evento_clientes for select to authenticated using (public.eh_ativo());
create policy "incluir cliente no evento"  on public.evento_clientes for insert to authenticated with check (public.eh_ativo());
create policy "atualizar cliente no evento" on public.evento_clientes for update to authenticated using (public.eh_ativo()) with check (public.eh_ativo());
create policy "tirar cliente do evento"    on public.evento_clientes for delete to authenticated using (public.eh_ativo());


-- =====================================================================
-- Chamados independentes: nascem com cliente e data,
-- e podem ser ligados a um problema depois
-- =====================================================================
alter table public.chamados add column if not exists cliente_id uuid references public.clientes(id) on delete cascade;
update public.chamados ch set cliente_id = p.cliente_id from public.problemas p where p.id = ch.problema_id and ch.cliente_id is null;
alter table public.chamados alter column cliente_id set not null;
alter table public.chamados alter column problema_id drop not null;
alter table public.chamados alter column assunto drop not null;
alter table public.chamados add column if not exists data_chamado date not null default current_date;
update public.chamados set data_chamado = criado_em::date where data_chamado = current_date and criado_em::date <> current_date;

-- Excluir um problema não apaga mais os chamados: eles só ficam sem problema vinculado
alter table public.chamados drop constraint if exists chamados_problema_id_fkey;
alter table public.chamados add constraint chamados_problema_id_fkey
  foreign key (problema_id) references public.problemas(id) on delete set null;
create index if not exists chamados_cliente_idx on public.chamados (cliente_id);

-- O problema vinculado precisa ser do mesmo cliente do chamado
create or replace function public.chamado_mesmo_cliente()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.problema_id is not null and not exists (
    select 1 from public.problemas where id = new.problema_id and cliente_id = new.cliente_id
  ) then
    raise exception 'O problema escolhido é de outro cliente';
  end if;
  return new;
end; $$;

drop trigger if exists chamados_mesmo_cliente on public.chamados;
create trigger chamados_mesmo_cliente
  before insert or update on public.chamados
  for each row execute function public.chamado_mesmo_cliente();


-- =====================================================================
-- PRIMEIRO HEAD
-- Depois de criar sua conta pelo app, rode a linha abaixo
-- trocando pelo seu e-mail. A partir daí você gerencia a equipe pela tela.
-- =====================================================================
-- update public.colaboradores set funcao = 'head' where email = 'seu@email.com';
