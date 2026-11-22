--  SPDX-License-Identifier: GPL-3.0-or-later
--  Capabilities: la única forma de que un proceso actúe sobre un objeto.
--
--  Teorema (Covered): tras cualquier operación que un proceso pueda pedir, cada
--  capability existente estaba ya en el sistema, o deriva de una que tenía al
--  menos esos derechos y el mismo objeto. La autoridad total nunca aumenta: una
--  capability no se puede falsificar ni ampliar.
--
--  Grant es la raíz de la autoridad. Solo la usa el kernel al crear un proceso
--  y ninguna llamada al sistema conduce a ella.
--
--  No es reentrante: quien llama debe tener las interrupciones apagadas.

pragma Unevaluated_Use_Of_Old (Allow);

package Cap_Core with
  SPARK_Mode,
  Abstract_State => State,
  Initializes    => State
is
   type U64 is mod 2**64 with Size => 64;

   Max_Procs   : constant := 4;
   Max_Slots   : constant := 16;
   Max_Objects : constant := 4;

   type Proc_Id is range 1 .. Max_Procs;
   type Slot_Id is range 0 .. Max_Slots - 1;
   type Object_Id is range 0 .. Max_Objects - 1;

   --  Sched: autoriza a fijar prioridad y presupuesto propios; el objeto es la
   --  prioridad máxima que se puede pedir.
   --  Region: una región de memoria compartida (objeto = región - 1). Recv
   --  autoriza a mapearla para leer; Send, además, para escribir.
   type Cap_Kind is (None, Endpoint, Console, Device, Sched, Region);

   type Cap is record
      Kind   : Cap_Kind;
      Object : Object_Id;
      Send   : Boolean;
      Recv   : Boolean;
      Grant  : Boolean;
   end record;

   type Cap_Table is array (Slot_Id) of Cap;
   type Cap_Store is array (Proc_Id) of Cap_Table;

   Status_Ok       : constant U64 := 0;
   Status_Invalid  : constant U64 := 1;
   Status_Denied   : constant U64 := 2;
   Status_Occupied : constant U64 := 3;

   No_Object : constant U64 := U64'Last;

   Right_Send  : constant U64 := 1;
   Right_Recv  : constant U64 := 2;
   Right_Grant : constant U64 := 4;

   function Valid_Proc (Proc : U64) return Boolean is
     (Proc >= 1 and then Proc <= U64 (Max_Procs));

   function Valid_Slot (Slot : U64) return Boolean is
     (Slot < U64 (Max_Slots));

   function Valid_Kind (Kind : U64) return Boolean is
     (Kind >= 1 and then Kind <= 5);

   function Decode_Kind (Kind : U64) return Cap_Kind is
     (if Kind = 1 then Endpoint
      elsif Kind = 2 then Console
      elsif Kind = 3 then Device
      elsif Kind = 4 then Sched
      else Region)
   with Pre => Valid_Kind (Kind);

   function Has_Right (C : Cap; Right : U64) return Boolean is
     (case Right is
        when Right_Send  => C.Send,
        when Right_Recv  => C.Recv,
        when Right_Grant => C.Grant,
        when others      => False);

   --  Src tiene el mismo objeto y al menos los derechos de C.
   function Subsumes (Src, C : Cap) return Boolean is
     (Src.Kind /= None
      and then Src.Kind = C.Kind
      and then Src.Object = C.Object
      and then (if C.Send then Src.Send)
      and then (if C.Recv then Src.Recv)
      and then (if C.Grant then Src.Grant));

   function Is_Covered (C : Cap; Before : Cap_Store) return Boolean is
     (C.Kind = None
      or else
        (for some P in Proc_Id =>
           (for some S in Slot_Id => Subsumes (Before (P) (S), C))))
   with Ghost;

   function Covered (After, Before : Cap_Store) return Boolean is
     (for all P in Proc_Id =>
        (for all S in Slot_Id => Is_Covered (After (P) (S), Before)))
   with Ghost;

   --  Las tablas de los demás procesos no han cambiado.
   function Others_Unchanged (After, Before : Cap_Store; P : Proc_Id) return Boolean is
     (for all Q in Proc_Id => (if Q /= P then After (Q) = Before (Q)))
   with Ghost;

   function Snapshot return Cap_Store with
     Ghost,
     Global => (Input => State);

   --  Raíz de la autoridad: solo para el kernel. Exige un hueco libre.
   function Grant
     (Proc, Slot, Kind, Object, Rights : U64) return U64
   with
     Side_Effects,
     Global        => (In_Out => State),
     Post          =>
       (if Grant'Result = Status_Ok
        then Valid_Proc (Proc)
          and then Others_Unchanged (Snapshot, Snapshot'Old, Proc_Id (Proc))),
     Export,
     Convention    => C,
     External_Name => "fb_cap_grant";

   --  Objeto de la capability si tiene ese tipo y ese derecho, o No_Object.
   function Check (Proc, Slot, Kind, Right : U64) return U64 with
     Global        => (Input => State),
     Post          =>
       (if Check'Result /= No_Object
        then Valid_Proc (Proc)
          and then Valid_Slot (Slot)
          and then Valid_Kind (Kind)
          and then Snapshot (Proc_Id (Proc)) (Slot_Id (Slot)).Kind = Decode_Kind (Kind)
          and then Has_Right (Snapshot (Proc_Id (Proc)) (Slot_Id (Slot)), Right)
          and then Check'Result
                     = U64 (Snapshot (Proc_Id (Proc)) (Slot_Id (Slot)).Object)),
     Export,
     Convention    => C,
     External_Name => "fb_cap_check";

   function Can_Receive (C : Cap; Object : U64) return Boolean is
     (C.Kind = Endpoint and then C.Recv and then U64 (C.Object) = Object);

   --  1 si el proceso puede recibir de ese endpoint.
   function Holds_Receive (Proc, Object : U64) return U64 with
     Global        => (Input => State),
     Post          =>
       (if Holds_Receive'Result = 1
        then Valid_Proc (Proc)
          and then (for some S in Slot_Id =>
                      Can_Receive (Snapshot (Proc_Id (Proc)) (S), Object))),
     Export,
     Convention    => C,
     External_Name => "fb_cap_holds_receive";

   --  1 si algún otro proceso puede recibir de ese endpoint. Si devuelve 0, el
   --  endpoint se queda sin servidor cuando Proc desaparezca.
   function Other_Receiver (Proc, Object : U64) return U64 with
     Global        => (Input => State),
     Post          =>
       (if Valid_Proc (Proc)
        then
          (Other_Receiver'Result = 0 or else Other_Receiver'Result = 1)
          and then
            (Other_Receiver'Result = 1)
            = (for some Q in Proc_Id =>
                 Q /= Proc_Id (Proc)
                 and then (for some S in Slot_Id =>
                             Can_Receive (Snapshot (Q) (S), Object)))),
     Export,
     Convention    => C,
     External_Name => "fb_cap_other_receiver";

   --  1 si alguna capability de algún proceso es de ese tipo y nombra ese
   --  objeto, 0 si no. Para saber si un objeto ya no lo alcanza nadie.
   function Refers (Kind, Object : U64) return U64 with
     Global        => (Input => State),
     Post          =>
       (if Valid_Kind (Kind) and then Object < U64 (Max_Objects)
        then (Refers'Result = 1)
             = (for some P in Proc_Id =>
                  (for some S in Slot_Id =>
                     Snapshot (P) (S).Kind = Decode_Kind (Kind)
                     and then U64 (Snapshot (P) (S).Object) = Object))
        else Refers'Result = 0),
     Export,
     Convention    => C,
     External_Name => "fb_cap_refers";

   --  Indica si hay una capability en ese hueco.
   function Held (Proc, Slot : U64) return U64 with
     Global        => (Input => State),
     Export,
     Convention    => C,
     External_Name => "fb_cap_held";

   --  Crea en Dst una copia de Src con los derechos pedidos. Se rechaza si
   --  pide alguno que Src no tiene.
   function Derive (Proc, Src, Dst, Rights : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Post          =>
       Covered (Snapshot, Snapshot'Old)
       and then
         (if Valid_Proc (Proc)
          then Others_Unchanged (Snapshot, Snapshot'Old, Proc_Id (Proc)))
       and then
         (if Derive'Result = Status_Ok
          then Valid_Proc (Proc)
            and then Valid_Slot (Src)
            and then Valid_Slot (Dst)
            and then Subsumes
                       (Snapshot'Old (Proc_Id (Proc)) (Slot_Id (Src)),
                        Snapshot (Proc_Id (Proc)) (Slot_Id (Dst)))),
     Export,
     Convention    => C,
     External_Name => "fb_cap_derive";

   --  Copia una capability a otro proceso.
   function Transfer (From_Proc, From_Slot, To_Proc, To_Slot : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Post          =>
       Covered (Snapshot, Snapshot'Old)
       and then
         (if Valid_Proc (To_Proc)
          then Others_Unchanged (Snapshot, Snapshot'Old, Proc_Id (To_Proc)))
       and then
         (if Transfer'Result = Status_Ok
          then Valid_Proc (From_Proc)
            and then Valid_Proc (To_Proc)
            and then Valid_Slot (From_Slot)
            and then Valid_Slot (To_Slot)
            and then Snapshot (Proc_Id (To_Proc)) (Slot_Id (To_Slot))
                       = Snapshot'Old (Proc_Id (From_Proc)) (Slot_Id (From_Slot))),
     Export,
     Convention    => C,
     External_Name => "fb_cap_transfer";

   function Delete (Proc, Slot : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Post          =>
       Covered (Snapshot, Snapshot'Old)
       and then
         (if Delete'Result = Status_Ok
          then Valid_Proc (Proc)
            and then Valid_Slot (Slot)
            and then Snapshot (Proc_Id (Proc)) (Slot_Id (Slot)).Kind = None
            and then Others_Unchanged (Snapshot, Snapshot'Old, Proc_Id (Proc))),
     Export,
     Convention    => C,
     External_Name => "fb_cap_delete";

   --  Vacía la tabla de un proceso que termina.
   function Clear (Proc : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Post          =>
       Covered (Snapshot, Snapshot'Old)
       and then
         (if Clear'Result = Status_Ok
          then Valid_Proc (Proc)
            and then (for all S in Slot_Id => Snapshot (Proc_Id (Proc)) (S).Kind = None)),
     Export,
     Convention    => C,
     External_Name => "fb_cap_clear";

end Cap_Core;
