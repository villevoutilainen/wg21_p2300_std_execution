/*
 * Copyright (c) 2022 NVIDIA Corporation
 *
 * Licensed under the Apache License Version 2.0 with LLVM Exceptions
 * (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 *
 *   https://llvm.org/LICENSE.txt
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#pragma once

#include "../../stdexec/execution.hpp"
#include <type_traits>

#include "common.cuh"

namespace nvexec::STDEXEC_STREAM_DETAIL_NS {

  namespace _transfer {
    template <class CvrefSenderId, class ReceiverId>
    struct operation_state_t {
      using Sender = __cvref_t<CvrefSenderId>;
      using Receiver = stdexec::__t<ReceiverId>;
      using Env = typename operation_state_base_t<ReceiverId>::env_t;

      struct __t : operation_state_base_t<ReceiverId> {
        using __id = operation_state_t;
        using variant_t = variant_storage_t<Sender, Env>;

        struct receiver_t {
          __t& op_state_;

          template <same_as<receiver_t> _Self, same_as<set_value_t> Tag, class... As>
            requires __callable<Tag, Receiver&&, As...>
          STDEXEC_DEFINE_CUSTOM(void set_value)(this _Self&& self, Tag, As&&... as) noexcept {
            Tag()((Receiver&&) self.op_state_.rcvr_, (As&&) as...);
          }

          template <same_as<receiver_t> _Self, same_as<set_error_t> Tag, class Error>
            requires __callable<Tag, Receiver&&, Error>
          STDEXEC_DEFINE_CUSTOM(void set_error)(this _Self&& self, Tag, Error&& error) noexcept {
            Tag()((Receiver&&) self.op_state_.rcvr_, (Error&&) error);
          }

          template <same_as<receiver_t> _Self, same_as<set_stopped_t> Tag>
            requires __callable<Tag, Receiver&&>
          STDEXEC_DEFINE_CUSTOM(void set_stopped)(this _Self&& self, Tag) noexcept {
            Tag()((Receiver&&) self.op_state_.rcvr_);
          }

          STDEXEC_DEFINE_CUSTOM(Env get_env)(this const receiver_t& self, get_env_t) noexcept {
            return self.op_state_.make_env();
          }
        };

        using task_t = continuation_task_t<receiver_t, variant_t>;

        cudaError_t status_{cudaSuccess};
        context_state_t context_state_;

        host_ptr<variant_t> storage_;
        task_t* task_;

        ::cuda::std::atomic_flag started_{};

        using enqueue_receiver =
          stdexec::__t<stream_enqueue_receiver<stdexec::__id<Env>, variant_t>>;
        using inner_op_state_t = connect_result_t<Sender, enqueue_receiver>;
        host_ptr<__decay_t<Env>> env_{};
        inner_op_state_t inner_op_;

        STDEXEC_DEFINE_CUSTOM(void start)(this __t& op, start_t) noexcept {
          op.started_.test_and_set(::cuda::std::memory_order::relaxed);

          if (op.status_ != cudaSuccess) {
            // Couldn't allocate memory for operation state, complete with error
            stdexec::set_error(std::move(op.rcvr_), std::move(op.status_));
            return;
          }

          stdexec::start(op.inner_op_);
        }

        __t(Sender&& sender, Receiver&& rcvr, context_state_t context_state)
          : operation_state_base_t<ReceiverId>((Receiver&&) rcvr, context_state)
          , context_state_(context_state)
          , storage_(make_host<variant_t>(this->status_, context_state.pinned_resource_))
          , task_(make_host<task_t>(
                    this->status_,
                    context_state.pinned_resource_,
                    receiver_t{*this},
                    storage_.get(),
                    this->get_stream(),
                    context_state.pinned_resource_)
                    .release())
          , env_(make_host(this->status_, context_state_.pinned_resource_, this->make_env()))
          , inner_op_{connect(
              (Sender&&) sender,
              enqueue_receiver{
                env_.get(),
                storage_.get(),
                task_,
                context_state_.hub_->producer()})} {
          if (this->status_ == cudaSuccess) {
            this->status_ = task_->status_;
          }
        }

        STDEXEC_IMMOVABLE(__t);
      };
    };
  }

  template <class SenderId>
  struct transfer_sender_t {
    using Sender = stdexec::__t<SenderId>;

    struct __t : stream_sender_base {
      using __id = transfer_sender_t;

      template <class Self, class Receiver>
      using op_state_th = //
        stdexec::__t<
          _transfer::operation_state_t< __cvref_id<Self, Sender>, stdexec::__id<Receiver>>>;

      context_state_t context_state_;
      Sender sndr_;

      template <class... Ts>
      using _set_value_t = completion_signatures<set_value_t(__decay_t<Ts>&&...)>;

      template <class Ty>
      using _set_error_t = completion_signatures<set_error_t(__decay_t<Ty>&&)>;

      template <class Self, class Env>
      using _completion_signatures_t = //
        __try_make_completion_signatures<
          __copy_cvref_t<Self, Sender>,
          Env,
          completion_signatures< //
            set_stopped_t(),
            set_error_t(cudaError_t)>,
          __q<_set_value_t>,
          __q<_set_error_t>>;

      template <__decays_to<__t> Self, receiver Receiver>
        requires receiver_of<Receiver, _completion_signatures_t<Self, env_of_t<Receiver>>>
      STDEXEC_DEFINE_CUSTOM(auto connect)(this Self&& self, connect_t, Receiver rcvr)
        -> op_state_th<Self, Receiver> {
        return op_state_th<Self, Receiver>{
          (Sender&&) self.sndr_, (Receiver&&) rcvr, self.context_state_};
      }

      template <__decays_to<__t> Self, class Env>
      STDEXEC_DEFINE_CUSTOM(auto get_completion_signatures)(
        this Self&&,
        get_completion_signatures_t,
        Env&&) -> dependent_completion_signatures<Env>;

      template <__decays_to<__t> Self, class Env>
      STDEXEC_DEFINE_CUSTOM(auto get_completion_signatures)(
        this Self&&,
        get_completion_signatures_t,
        Env&&) -> _completion_signatures_t<Self, Env>
        requires true;

      STDEXEC_DEFINE_CUSTOM(auto get_env)(this const __t& self, get_env_t) noexcept
        -> env_of_t<const Sender&> {
        return stdexec::get_env(self.sndr_);
      }

      __t(context_state_t context_state, Sender sndr)
        : context_state_(context_state)
        , sndr_{(Sender&&) sndr} {
      }
    };
  };
}
