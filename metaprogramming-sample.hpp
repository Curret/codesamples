// The following is an index operator for a view object used as part of an 
// Entity-Component-System framework. A ComponentView object acts as a view of
// all the entities that share a given set of components (the COMPS template 
// paramter pack in this case). The index operator takes the given index i and
// returns a ComponentSet (a tuple object, effectively) containing the
// components at that index of the view (index in the view having no 
// correlation with entity ID or index in the original array).

// ID_T: type of the Entity ID object.
// COMPS: list of component types the view contains.
template <typename ID_T, typename ...COMPS>
ComponentSet<ID_T, COMPS...>
ComponentView<ID_T, COMPS...>::operator[](size_t i)
{
  // Retrieves the first type in the template parameter pack.
  // Const and * have special meanings in the ecs framework, and should be 
  // stripped. The StripConstPtr template is used to do this.
  using FirstComponentType = 
    std::tuple_element_t<0, std::tuple<StripConstPtr<COMPS>...>>;

  // Retern a ComponentSet object with each component attached to the entity 
  // at index i in this ComponentView. Components may be 'optional' (denoted by
  // being a pointer in the components list), meaning that a given entity in
  // this view may lack that component while still being included. In that
  // case, the component is returned as a pointer, so the pointer retrieved for
  // the component should not be converted into an lvalue reference while
  // constructing the ComponentSet (controlled by the MaybeDeref template).
  size_t j = 0;
  return ComponentSet<ID_T, COMPS...>{
      world_.template comp_get_entity<FirstComponentType>(ind_[0][i]),        // First parameter to the constructor is the Entity ID, retrieved here.
      // Begin components list
      (                                                                       // Beginning of template parameter pack expansion for COMPS.
        __detail::MaybeDeref<std::is_pointer_v<COMPS>>::deref                 // MaybeDeref template, converts to an lvalue ref if COMPS is not a pointer.
        (
          world_.                                                             // World is the root of the ecs framework, containing all entity data. The view object maintains a reference to the world.
          compReg_.                                                           // CompReg is the object within the world that manages component arrays.
          template get_array<StripConstPtr<COMPS>>().                         // Retrieves the array for the specific component type.
          get_by_index(ind_[j++][i])                                          // Retrieves the component pointer for the component index stored in this view.
        )
      )...                                                                    // End template parameter pack expansion.
    };
}
