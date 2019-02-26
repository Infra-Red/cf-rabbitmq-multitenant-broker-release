package broker_test

import (
	"context"
	"fmt"
	"net/http"

	"rabbitmq-service-broker/broker/fakes"

	rabbithole "github.com/michaelklishin/rabbit-hole"

	"github.com/pivotal-cf/brokerapi"

	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"
)

var _ = Describe("Provisioning a RMQ service instance", func() {
	var (
		client *fakes.FakeAPIClient
		broker brokerapi.ServiceBroker
		ctx    context.Context
	)

	BeforeEach(func() {
		client = new(fakes.FakeAPIClient)
		broker = defaultServiceBroker(defaultConfig(), client)
		ctx = context.TODO()
		client.GetVhostReturns(nil, fmt.Errorf("vhost does not exist"))
		client.PutVhostReturns(&http.Response{StatusCode: http.StatusNoContent}, nil)
		//		client.DeleteVhostReturns(&http.Response{StatusCode: http.StatusNoContent}, nil)
		client.UpdatePermissionsInReturns(&http.Response{StatusCode: http.StatusNoContent}, nil)
		client.PutPolicyReturns(&http.Response{StatusCode: http.StatusNoContent}, nil)
	})

	It("creates a vhost", func() {
		_, err := broker.Provision(ctx, "my-service-id", brokerapi.ProvisionDetails{}, false)
		Expect(err).NotTo(HaveOccurred())

		Expect(client.PutVhostCallCount()).To(Equal(1))
		Expect(client.PutVhostArgsForCall(0)).To(Equal("my-service-id"))
	})

	When("the vhost already exists", func() {
		It("returns ErrInstanceAlreadyExists error", func() {
			client.GetVhostReturns(&rabbithole.VhostInfo{}, nil)

			_, err := broker.Provision(ctx, "my-service-id", brokerapi.ProvisionDetails{}, false)
			Expect(err).To(Equal(brokerapi.ErrInstanceAlreadyExists))

			Expect(client.GetVhostCallCount()).To(Equal(1))
			Expect(client.GetVhostArgsForCall(0)).To(Equal("my-service-id"))
			Expect(client.PutVhostCallCount()).To(Equal(0))
		})
	})

	When("the vhost creation fails", func() {
		It("returns an error when the RMQ API returns an error", func() {
			client.PutVhostReturns(nil, fmt.Errorf("vhost-creation-failed"))

			_, err := broker.Provision(ctx, "my-service-id", brokerapi.ProvisionDetails{}, false)
			Expect(err).To(MatchError("vhost-creation-failed"))
		})

		It("returns an error when the RMQ API returns a bad HTTP response code", func() {
			client.PutVhostReturns(&http.Response{StatusCode: http.StatusInternalServerError}, nil)

			_, err := broker.Provision(ctx, "my-service-id", brokerapi.ProvisionDetails{}, false)
			Expect(err).To(MatchError("http request failed with status code: 500"))
		})
	})

	It("grants permissions on the vhost to the service broker RMQ admin user", func() {
		_, err := broker.Provision(ctx, "my-service-id", brokerapi.ProvisionDetails{}, false)
		Expect(err).NotTo(HaveOccurred())

		Expect(client.UpdatePermissionsInCallCount()).To(Equal(1))
		vhost, username, permissions := client.UpdatePermissionsInArgsForCall(0)
		Expect(vhost).To(Equal("my-service-id"))
		Expect(username).To(Equal("default-admin-username"))
		Expect(permissions.Configure).To(Equal(".*"))
		Expect(permissions.Read).To(Equal(".*"))
		Expect(permissions.Write).To(Equal(".*"))
	})

	It("grants permissions on the vhost to the management RMQ user", func() {
		config := defaultConfig()
		config.RabbitMQConfig.Management.Username = "default-management-username"
		broker = defaultServiceBroker(config, client)

		_, err := broker.Provision(ctx, "my-service-id", brokerapi.ProvisionDetails{}, false)
		Expect(err).NotTo(HaveOccurred())

		Expect(client.UpdatePermissionsInCallCount()).To(Equal(2))
		vhost, username, permissions := client.UpdatePermissionsInArgsForCall(1)
		Expect(vhost).To(Equal("my-service-id"))
		Expect(username).To(Equal("default-management-username"))
		Expect(permissions.Configure).To(Equal(".*"))
		Expect(permissions.Read).To(Equal(".*"))
		Expect(permissions.Write).To(Equal(".*"))
	})

	When("the management RMQ user has not been set", func() {
		It("does not attempt to grant it permissions", func() {
			_, err := broker.Provision(ctx, "my-service-id", brokerapi.ProvisionDetails{}, false)
			Expect(err).NotTo(HaveOccurred())
			Expect(client.UpdatePermissionsInCallCount()).To(Equal(1))
		})
	})

	It("sets policies for the new instance", func() {
		config := defaultConfig()
		config.RabbitMQConfig.Policy.Enabled = true
		config.RabbitMQConfig.Policy.Name = "fake-policy-name"
		config.RabbitMQConfig.Policy.Definition = map[string]interface{}{"fake-policy-key": "fake-policy-value"}
		config.RabbitMQConfig.Policy.Priority = 42
		broker = defaultServiceBroker(config, client)

		_, err := broker.Provision(ctx, "my-service-id", brokerapi.ProvisionDetails{}, false)
		Expect(err).NotTo(HaveOccurred())

		Expect(client.PutPolicyCallCount()).To(Equal(1))
		vhost, policyName, policy := client.PutPolicyArgsForCall(0)
		Expect(vhost).To(Equal("my-service-id"))
		Expect(policyName).To(Equal("fake-policy-name"))
		Expect(policy.Definition).To(BeEquivalentTo(map[string]interface{}{"fake-policy-key": "fake-policy-value"}))
		Expect(policy.Priority).To(Equal(42))
	})

	When("there are no policies configured", func() {
		It("does not attempt to configure any", func() {
			_, err := broker.Provision(ctx, "my-service-id", brokerapi.ProvisionDetails{}, false)
			Expect(err).NotTo(HaveOccurred())

			Expect(client.PutPolicyCallCount()).To(Equal(0))
		})
	})
})
