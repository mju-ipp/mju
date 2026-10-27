-- 88. 학생·기업 화면 보기 전용 미리보기 (2026-10-27 사용자: "관리자 콘솔에서 기업이랑 학생이 어떻게 보이는지도 보고 싶다")
-- 계획 docs/PREVIEW.md 1단계. 재실행해도 안전(create or replace / drop if exists).
--
--  · admin_preview_identity(p_kind, p_id) → {ok, profile:{name, target_type, job_key, company, type1, manager, token, code}}
--      학생 앱 localStorage('ilhak_profile') 와 같은 모양 — 미리보기 탭이 sessionStorage 에 넣고 그대로 씀.
--      p_kind 'student' = students.id, 'company' = 기업명(company_codes.company). 로그인한 관리자 + 같은 센터만.
--      학생: 명단 값 + 초대코드(student_codes, 이름·전화 일치·active) + 서명토큰(make_student_token). 전화번호는 안 돌려줌.
--      기업: 기업 초대코드(active). 코드가 없으면 reason 'code'(기업 화면은 코드로만 열림).
--      토큰을 받아가는 함수라 부를 때마다 admin_logs 에 '화면 미리보기' 한 줄(누가·누구).
--  · my_chat_messages 에 p_peek(기본 false) — true 면 글만 주고 읽음(chat_student_reads) 기록 안 함.
--      학생이 넘겨도 자기 읽음만 안 남는 것이라 해 없음. 기존 호출(3개 인자)은 그대로 읽음 기록.

create or replace function public.admin_preview_identity(p_kind text, p_id text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare au public.admin_users; st public.students; v_code text; v_actor text; v_who text;
begin
  select * into au from admin_users where user_id = auth.uid();
  if au.user_id is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  select email into v_actor from auth.users where id = auth.uid();

  if p_kind = 'student' then
    begin
      select * into st from students where id = p_id::uuid and center_id = au.center_id;
    exception when invalid_text_representation then null;
    end;
    if st.id is null then return jsonb_build_object('ok', false, 'reason', 'student'); end if;
    select sc.code into v_code from student_codes sc
     where sc.center_id = au.center_id and sc.active
       and replace(trim(sc.name), ' ', '') = replace(trim(st.name), ' ', '')
       and regexp_replace(coalesce(sc.phone, ''), '\D', '', 'g') = regexp_replace(coalesce(st.phone, ''), '\D', '', 'g')
     order by sc.created_at desc limit 1;
    if v_code is null and st.phone is null then return jsonb_build_object('ok', false, 'reason', 'phone'); end if;
    v_who := '학생 ' || trim(st.name) || coalesce(' (' || st.company || ')', '');
    insert into admin_logs (actor, action, detail, center_id) values (v_actor, '화면 미리보기', v_who, au.center_id);
    return jsonb_build_object('ok', true, 'profile', jsonb_build_object(
      'name', trim(st.name), 'target_type', 'student',
      'job_key', st.job_keys[1], 'company', st.company, 'type1', st.type1, 'manager', st.manager,
      'token', case when st.phone is null then null else make_student_token(st.name, st.phone) end,
      'code', v_code));

  elsif p_kind = 'company' then
    select cc.code into v_code from company_codes cc
     where cc.center_id = au.center_id and cc.active and cc.company = p_id
     order by cc.created_at desc limit 1;
    if v_code is null then return jsonb_build_object('ok', false, 'reason', 'code'); end if;
    v_who := '기업 ' || p_id;
    insert into admin_logs (actor, action, detail, center_id) values (v_actor, '화면 미리보기', v_who, au.center_id);
    return jsonb_build_object('ok', true, 'profile', jsonb_build_object(
      'name', p_id, 'target_type', 'company', 'job_key', null, 'company', p_id,
      'type1', null, 'manager', null, 'token', null, 'code', v_code));
  end if;
  return jsonb_build_object('ok', false, 'reason', 'kind');
end $$;

revoke all on function public.admin_preview_identity(text, text) from public, anon;
grant execute on function public.admin_preview_identity(text, text) to authenticated, service_role;

-- my_chat_messages: 인자를 하나 늘리면 다른 함수가 되므로 옛 3개짜리를 지우고 새로 만든다(이름 붙인 호출은 그대로 동작).
drop function if exists public.my_chat_messages(text, text, uuid);
create or replace function public.my_chat_messages(p_code text default null, p_token text default null, p_room uuid default null, p_peek boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare st public.students; v jsonb;
begin
  st := _chat_me(p_code, p_token);
  if st.id is null then return jsonb_build_object('ok', false); end if;
  if not exists (select 1 from _chat_my_rooms(st) r where r.id = p_room) then
    return jsonb_build_object('ok', false, 'reason', 'room');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id, 'sender', x.sender, 'name', x.sender_name, 'body', x.body, 'at', x.created_at,
           'mine', x.sender = 'student' and x.student_id = st.id) order by x.created_at), '[]'::jsonb)
    into v
    from (select * from chat_messages m where m.room_id = p_room and not m.hidden
           order by m.created_at desc limit 200) x;
  if not coalesce(p_peek, false) then   -- (sql/88) 미리보기는 읽음 기록 안 함
    insert into chat_student_reads (room_id, student_id, read_at) values (p_room, st.id, now())
    on conflict (room_id, student_id) do update set read_at = excluded.read_at;
  end if;
  return jsonb_build_object('ok', true, 'messages', v);
end $$;

revoke all on function public.my_chat_messages(text, text, uuid, boolean) from public;
grant execute on function public.my_chat_messages(text, text, uuid, boolean) to anon, authenticated, service_role;
